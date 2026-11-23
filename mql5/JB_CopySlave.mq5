//+------------------------------------------------------------------+
//|                                                 JB_CopySlave.mq5 |
//|  JB Copier - SLAVE side.                                         |
//|  Long-polls the JB Copier relay for the master's position book   |
//|  and reconciles this account against it on every answer:         |
//|    master position new      -> open a copy (age/deviation/lot    |
//|                                checks, once per master ticket)   |
//|    master position gone     -> close its copies                  |
//|    master volume reduced    -> partial close in proportion       |
//|    master volume added      -> add-on copy (netting masters)     |
//|    master SL/TP changed     -> modify the copies                 |
//|  Master silent > InpStaleSec (EA removed, terminal or server     |
//|  down): FREEZE - nothing is opened or closed until it is back.   |
//|  Copies carry magic InpMagic and comment "CP#<master ticket>";   |
//|  state lives in terminal global variables JBCS.<magic>.*         |
//+------------------------------------------------------------------+
#property copyright "JB"
#property version   "1.01"
#property description "JB Copier slave: mirrors the master's positions from the JB Copier relay server."

#include <Trade\Trade.mqh>
#include "JB_CopierNet.mqh"

#define SLAVE_VERSION "1.01"

enum ENUM_LOT_MODE
  {
   LOT_FIXED         = 0, // Fixed lots = InpLotValue
   LOT_MULTIPLIER    = 1, // Master lots x InpLotValue
   LOT_BALANCE_RATIO = 2, // Master lots x slave/master balance x InpLotValue
   LOT_EQUITY_RATIO  = 3  // Master lots x slave/master equity x InpLotValue
  };

enum ENUM_SLTP_MODE
  {
   SLTP_PRICE    = 0, // Same SL/TP prices as the master
   SLTP_DISTANCE = 1  // Same SL/TP distance from the entry (other broker's quotes)
  };

input group "Server"
input string                InpServerUrl   = "http://127.0.0.1:8787"; // Relay server URL
input string                InpChannel     = "main";                  // Channel name
input string                InpSlaveKey    = "";                      // Slave key (copy_server.json)
input string                InpSlaveId     = "";                      // Name on the dashboard ("" = account number)
input ENUM_COPIER_TRANSPORT InpTransport   = TRANSPORT_WEBREQUEST;    // Transport
input int                   InpWaitMs      = 1000;  // Long-poll wait, ms (0 = plain polling)
input int                   InpPollMs      = 100;   // Pause between polls, ms
input int                   InpTimeoutMs   = 3000;  // HTTP timeout on top of the wait, ms
input int                   InpStaleSec    = 10;    // Master silent this long = offline (freeze)

input group "Lot size"
input ENUM_LOT_MODE         InpLotMode        = LOT_BALANCE_RATIO; // Lot mode
input double                InpLotValue       = 1.0;   // Fixed lots / multiplier
input double                InpMaxLot         = 10.0;  // Maximum lots per copy
input bool                  InpRoundUpToMin   = true;  // Below broker minimum: use minimum (false = skip)
input bool                  InpAdjustContract = true;  // Scale lots when contract sizes differ

input group "Symbols and filters"
input string                InpSymbolMap    = "";  // Explicit map, e.g. GOLD=XAUUSD,US30=DJ30
input string                InpMasterSuffix = "";  // Suffix to strip from master symbols (e.g. .fx)
input string                InpSlaveSuffix  = "";  // Suffix to add on this account
input string                InpSymbolsAllow = "";  // Copy only these master symbols ("" or all = all)
input string                InpMagicAllow   = "";  // Copy only these master magics ("" or all = all)

input group "Execution"
input bool                  InpCopyExisting    = false; // Copy master positions already open at start
input int                   InpMaxSignalAgeSec = 60;    // Don't open copies of older master trades (0 = off)
input int                   InpMaxDeviationPts = 50;    // Skip if price moved this many points against us (0 = off)
input bool                  InpCopySLTP        = true;  // Copy SL/TP and their changes
input ENUM_SLTP_MODE        InpSLTPMode        = SLTP_PRICE; // SL/TP mode
input bool                  InpReverse         = false; // Reverse copy (BUY <-> SELL)
input bool                  InpCopyAddOns      = true;  // Follow master volume increases (netting masters)
input int                   InpSlippagePts     = 30;    // Max slippage, points
input long                  InpMagic           = 26101701; // Magic number of the copies
input string                InpCommentPrefix   = "CP#";    // Comment prefix (+ master ticket)

input group "Protection"
input int                   InpMaxCopies      = 50;  // Maximum open copies
input double                InpDailyLossLimit = 0;   // Stop opening copies after this daily loss (0 = off)

//+------------------------------------------------------------------+
struct MPos               // master position from the snapshot
  {
   ulong  ticket;
   string symbol;
   int    type;
   double volume;
   double open;
   double sl;
   double tp;
   long   magic;
   long   time;
   double contract;
  };

struct CPos               // copy on this account
  {
   ulong  ticket;
   ulong  master;
   string symbol;
   int    type;
   double volume;
   double open;
   double sl;
   double tp;
   long   time_msc;
  };

CCopierHttp g_http;
CTrade      g_trade;

MPos    g_m[];
long    g_m_login = 0;
string  g_m_server = "", g_m_currency = "";
double  g_m_balance = 0, g_m_equity = 0;
long    g_m_now = 0;

long    g_seq = -1;
string  g_boot = "";
long    g_age_ms = -1;          // master age reported by the server ...
ulong   g_rx_ms = 0;            // ... at this local GetTickCount64
bool    g_have_snapshot = false;
bool    g_baseline_done = false;
ulong   g_baseline[];

string  g_id = "";
string  g_gv = "";
string  g_state = "starting";
string  g_last_err = "", g_last_err_logged = "";
ulong   g_last_err_log_ms = 0;
string  g_last_action = "";
bool    g_hedging_checked = false, g_hedging = false;
bool    g_warned_same = false;
bool    g_loss_blocked = false;
double  g_day_pl = 0;
int     g_copies = 0;
double  g_floating = 0;
ulong   g_last_status_ms = 0, g_last_gc_ms = 0, g_last_loss_ms = 0;
bool    g_gv_dirty = false;

string  g_map_from[], g_map_to[], g_cache_from[], g_cache_to[];
string  g_sym_allow[];
long    g_magic_allow[];
string  g_cool_key[];
ulong   g_cool_until[];

//+------------------------------------------------------------------+
//| small helpers                                                    |
//+------------------------------------------------------------------+
string Trimmed(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

bool IsAll(string s) { s = Trimmed(s); StringToLower(s); return s == "" || s == "all" || s == "*"; }   // no filter

int SplitList(const string list, string &out[])
  {
   ArrayResize(out, 0);
   string parts[];
   int n = StringSplit(list, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = Trimmed(parts[i]);
      if(p == "") continue;
      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = p;
     }
   return ArraySize(out);
  }

bool InStrings(const string v, const string &a[])
  {
   for(int i = 0; i < ArraySize(a); i++) if(a[i] == v) return true;
   return false;
  }

bool InLongs(const long v, const long &a[])
  {
   for(int i = 0; i < ArraySize(a); i++) if(a[i] == v) return true;
   return false;
  }

void LogError(const string msg)
  {
   g_last_err = msg;
   ulong now = GetTickCount64();
   if(msg != g_last_err_logged || now - g_last_err_log_ms > 30000)
     {
      Print("JBCS: ", msg);
      g_last_err_logged = msg;
      g_last_err_log_ms = now;
     }
  }

void Action(const string msg)
  {
   g_last_action = TimeToString(TimeLocal(), TIME_SECONDS) + " " + msg;
   Print("JBCS: ", msg);
  }

string Clean(string s) { StringReplace(s, "|", "/"); StringReplace(s, "\n", " "); return s; }

//--- global-variable state: JBCS.<magic>.<kind>.<id>
//    H = master ticket handled (1 copied, 2 skipped), R = slave/master lot ratio,
//    V = last seen master volume, P = slave position -> master ticket
string GvName(const string kind, const ulong id) { return g_gv + kind + "." + IntegerToString((long)id); }
double GvGet(const string kind, const ulong id, const double def)
  {
   string n = GvName(kind, id);
   return GlobalVariableCheck(n) ? GlobalVariableGet(n) : def;
  }
void GvSet(const string kind, const ulong id, const double v) { GlobalVariableSet(GvName(kind, id), v); g_gv_dirty = true; }
void GvDel(const string kind, const ulong id) { GlobalVariableDel(GvName(kind, id)); g_gv_dirty = true; }

//--- per-object cool-down after a trade action (the position list lags OrderSend a little)
bool Cooling(const string kind, const ulong id)
  {
   string k = kind + IntegerToString((long)id);
   for(int i = 0; i < ArraySize(g_cool_key); i++)
      if(g_cool_key[i] == k) return GetTickCount64() < g_cool_until[i];
   return false;
  }
void SetCool(const string kind, const ulong id, const int ms)
  {
   string k = kind + IntegerToString((long)id);
   ulong until = GetTickCount64() + (ulong)ms;
   for(int i = 0; i < ArraySize(g_cool_key); i++)
      if(g_cool_key[i] == k) { g_cool_until[i] = until; return; }
   int n = ArraySize(g_cool_key);
   ArrayResize(g_cool_key, n + 1);
   ArrayResize(g_cool_until, n + 1);
   g_cool_key[n] = k;
   g_cool_until[n] = until;
  }
void PruneCool(void)
  {
   ulong now = GetTickCount64();
   int j = 0;
   for(int i = 0; i < ArraySize(g_cool_key); i++)
      if(g_cool_until[i] > now) { g_cool_key[j] = g_cool_key[i]; g_cool_until[j] = g_cool_until[i]; j++; }
   ArrayResize(g_cool_key, j);
   ArrayResize(g_cool_until, j);
  }

double LotsDown(const string sym, const double v)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   int d = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(MathFloor(v / step + 1e-7) * step, d);
  }

bool Succeeded(const uint rc) { return rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED; }

int SlaveType(const int master_type) { return InpReverse ? 1 - master_type : master_type; }
string Side(const int type) { return type == POSITION_TYPE_BUY ? "BUY" : "SELL"; }

int FindMaster(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_m); i++) if(g_m[i].ticket == ticket) return i;
   return -1;
  }

bool InBaseline(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_baseline); i++) if(g_baseline[i] == ticket) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| server                                                           |
//+------------------------------------------------------------------+
bool ParseSnapshot(string &lines[], const int n)
  {
   MPos   tmp[];
   bool   have_a = false;
   long   login = 0, now = 0;
   string server = "", ccy = "";
   double bal = 0, eq = 0;
   for(int i = 1; i < n; i++)
     {
      string l = Trimmed(lines[i]);
      if(l == "") continue;
      string f[];
      int k = StringSplit(l, '|', f);
      if(f[0] == "A" && k >= 8)
        {
         login = StringToInteger(f[1]); server = f[2]; ccy = f[3];
         bal = StringToDouble(f[4]); eq = StringToDouble(f[5]); now = StringToInteger(f[7]);
         have_a = true;
        }
      else if(f[0] == "P" && k >= 12)
        {
         int j = ArraySize(tmp);
         ArrayResize(tmp, j + 1);
         tmp[j].ticket   = (ulong)StringToInteger(f[1]);
         tmp[j].symbol   = f[2];
         tmp[j].type     = (int)StringToInteger(f[3]);
         tmp[j].volume   = StringToDouble(f[4]);
         tmp[j].open     = StringToDouble(f[5]);
         tmp[j].sl       = StringToDouble(f[6]);
         tmp[j].tp       = StringToDouble(f[7]);
         tmp[j].magic    = StringToInteger(f[8]);
         tmp[j].time     = StringToInteger(f[9]);
         tmp[j].contract = StringToDouble(f[10]);
         if(tmp[j].ticket == 0 || tmp[j].volume <= 0 || (tmp[j].type != 0 && tmp[j].type != 1))
           { LogError("bad position line from master: " + l); return false; }
        }
     }
   g_have_snapshot = have_a;
   if(!have_a) { ArrayResize(g_m, 0); return true; }
   g_m_login = login; g_m_server = server; g_m_currency = ccy;
   g_m_balance = bal; g_m_equity = eq; g_m_now = now;
   ArrayResize(g_m, ArraySize(tmp));
   for(int i = 0; i < ArraySize(tmp); i++) g_m[i] = tmp[i];
   return true;
  }

bool Poll(void)
  {
   int wait = (g_seq < 0) ? 0 : MathMax(0, InpWaitMs);
   string path = StringFormat("/v1/%s/pull?id=%s&seq=%I64d&boot=%s&wait=%d", InpChannel, g_id, g_seq, g_boot, wait);
   string resp;
   int status;
   if(!g_http.Request("GET", path, "", resp, status, wait + InpTimeoutMs))
     {
      LogError("server unreachable: " + g_http.error);
      return false;
     }
   if(status == 403) { LogError("server rejected the slave key / channel"); return false; }
   if(status != 200) { LogError(StringFormat("server answered HTTP %d: %s", status, resp)); return false; }

   string lines[];
   int n = StringSplit(resp, '\n', lines);
   string h[];
   if(n < 1 || StringSplit(Trimmed(lines[0]), '|', h) < 6 || h[0] != "S")
     {
      LogError("unexpected server answer: " + StringSubstr(resp, 0, 80));
      return false;
     }
   g_rx_ms  = GetTickCount64();
   g_age_ms = StringToInteger(h[2]);
   if(h[4] == "FULL" && !ParseSnapshot(lines, n))
      return false;
   g_seq  = StringToInteger(h[1]);
   g_boot = h[5];
   if(g_last_err != "" && StringFind(g_last_err, "server") == 0) g_last_err = "";
   return true;
  }

bool MasterFresh(void)
  {
   if(!g_have_snapshot || g_age_ms < 0 || g_rx_ms == 0) return false;
   long age = g_age_ms + (long)(GetTickCount64() - g_rx_ms);
   return age <= (long)InpStaleSec * 1000;
  }

void SendStatus(void)
  {
   string body = StringFormat("%I64d|%s|%s|%.2f|%.2f|%d|%.2f|%s|%s",
                              AccountInfoInteger(ACCOUNT_LOGIN), Clean(AccountInfoString(ACCOUNT_SERVER)),
                              AccountInfoString(ACCOUNT_CURRENCY), AccountInfoDouble(ACCOUNT_BALANCE),
                              AccountInfoDouble(ACCOUNT_EQUITY), g_copies, g_floating, Clean(g_state), Clean(g_last_err));
   string resp;
   int status;
   g_http.Request("POST", StringFormat("/v1/%s/status?id=%s", InpChannel, g_id), body, resp, status, InpTimeoutMs);
  }

//+------------------------------------------------------------------+
//| symbols, lots, stops                                             |
//+------------------------------------------------------------------+
string ResolveSymbol(const string ms)
  {
   for(int i = 0; i < ArraySize(g_cache_from); i++) if(g_cache_from[i] == ms) return g_cache_to[i];
   string r = "";
   for(int i = 0; i < ArraySize(g_map_from); i++) if(g_map_from[i] == ms) { r = g_map_to[i]; break; }
   if(r == "")
     {
      string base = ms;
      int ls = StringLen(InpMasterSuffix);
      if(ls > 0 && StringLen(ms) > ls && StringSubstr(ms, StringLen(ms) - ls) == InpMasterSuffix)
         base = StringSubstr(ms, 0, StringLen(ms) - ls);
      bool custom;
      if(SymbolExist(base + InpSlaveSuffix, custom))  r = base + InpSlaveSuffix;
      else if(SymbolExist(ms, custom))                r = ms;
      else if(SymbolExist(base, custom))              r = base;
      else
         for(int i = 0; i < SymbolsTotal(false); i++)
           {
            string s = SymbolName(i, false);
            if(StringFind(s, base) == 0 && StringLen(s) <= StringLen(base) + 5) { r = s; break; }
           }
     }
   if(r == "" || !SymbolSelect(r, true)) return "";
   int n = ArraySize(g_cache_from);
   ArrayResize(g_cache_from, n + 1);
   ArrayResize(g_cache_to, n + 1);
   g_cache_from[n] = ms;
   g_cache_to[n] = r;
   if(r != ms) PrintFormat("JBCS: master symbol %s -> %s", ms, r);
   return r;
  }

double CalcLots(const MPos &m, const string sym)
  {
   double lots = 0;
   switch(InpLotMode)
     {
      case LOT_FIXED:         lots = InpLotValue; break;
      case LOT_MULTIPLIER:    lots = m.volume * InpLotValue; break;
      case LOT_BALANCE_RATIO: lots = g_m_balance > 0 ? m.volume * AccountInfoDouble(ACCOUNT_BALANCE) / g_m_balance * InpLotValue : 0; break;
      case LOT_EQUITY_RATIO:  lots = g_m_equity > 0 ? m.volume * AccountInfoDouble(ACCOUNT_EQUITY) / g_m_equity * InpLotValue : 0; break;
     }
   if(InpAdjustContract && InpLotMode != LOT_FIXED && m.contract > 0)
     {
      double sc = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
      if(sc > 0) lots *= m.contract / sc;
     }
   lots = MathMin(lots, InpMaxLot);
   if(lots <= 0) return 0;
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double v = LotsDown(sym, lots);
   if(v < vmin) v = InpRoundUpToMin ? vmin : 0;
   if(vmax > 0 && v > vmax) v = LotsDown(sym, vmax);
   return v;
  }

//--- SL/TP for a copy of type stype that entered at base
void DesiredStops(const MPos &m, const string sym, const double base, double &sl, double &tp)
  {
   sl = 0;
   tp = 0;
   if(!InpCopySLTP) return;
   double a = InpReverse ? m.tp : m.sl;   // master level that becomes our SL
   double b = InpReverse ? m.sl : m.tp;   // master level that becomes our TP
   if(InpSLTPMode == SLTP_PRICE) { sl = a; tp = b; }
   else
     {
      sl = a > 0 ? base + (a - m.open) : 0;
      tp = b > 0 ? base + (b - m.open) : 0;
     }
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = sl > 0 ? NormalizeDouble(sl, digits) : 0;
   tp = tp > 0 ? NormalizeDouble(tp, digits) : 0;
  }

//+------------------------------------------------------------------+
//| copies                                                           |
//+------------------------------------------------------------------+
ulong MasterOf(const ulong pos_ticket, const string comment)
  {
   double v = GvGet("P", pos_ticket, 0);
   if(v > 0) return (ulong)v;
   int lp = StringLen(InpCommentPrefix);
   if(lp > 0 && StringFind(comment, InpCommentPrefix) == 0)
     {
      ulong t = (ulong)StringToInteger(StringSubstr(comment, lp));
      if(t > 0) { GvSet("P", pos_ticket, (double)t); return t; }
     }
   return 0;
  }

int CollectCopies(CPos &c[])
  {
   ArrayResize(c, 0);
   g_floating = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      ulong m = MasterOf(t, PositionGetString(POSITION_COMMENT));
      if(m == 0) continue;
      int k = ArraySize(c);
      ArrayResize(c, k + 1);
      c[k].ticket   = t;
      c[k].master   = m;
      c[k].symbol   = PositionGetString(POSITION_SYMBOL);
      c[k].type     = (int)PositionGetInteger(POSITION_TYPE);
      c[k].volume   = PositionGetDouble(POSITION_VOLUME);
      c[k].open     = PositionGetDouble(POSITION_PRICE_OPEN);
      c[k].sl       = PositionGetDouble(POSITION_SL);
      c[k].tp       = PositionGetDouble(POSITION_TP);
      c[k].time_msc = PositionGetInteger(POSITION_TIME_MSC);
      g_floating   += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   g_copies = ArraySize(c);
   return g_copies;
  }

bool HasCopy(const CPos &c[], const ulong master)
  {
   for(int i = 0; i < ArraySize(c); i++) if(c[i].master == master) return true;
   return false;
  }

void CloseCopy(const CPos &c, const string why)
  {
   if(Cooling("C", c.ticket)) return;
   g_trade.SetTypeFillingBySymbol(c.symbol);
   bool ok = g_trade.PositionClose(c.ticket);
   uint rc = g_trade.ResultRetcode();
   if(ok && Succeeded(rc))
     {
      Action(StringFormat("CLOSE %s %s %s #%I64u (master #%I64u: %s)", Side(c.type),
                          DoubleToString(c.volume, 2), c.symbol, c.ticket, c.master, why));
      SetCool("C", c.ticket, 3000);
     }
   else
     {
      SetCool("C", c.ticket, 3000);
      LogError(StringFormat("close #%I64u failed: %u %s", c.ticket, rc, g_trade.ResultRetcodeDescription()));
     }
  }

void MarkSkip(const MPos &m, const string why)
  {
   GvSet("H", m.ticket, 2);
   PrintFormat("JBCS: not copying master #%I64u %s %s %s: %s", m.ticket, Side(m.type),
               DoubleToString(m.volume, 2), m.symbol, why);
  }

void TryOpen(const MPos &m)
  {
   if(GvGet("H", m.ticket, 0) != 0 || Cooling("O", m.ticket)) return;

   long age = g_m_now - m.time + g_age_ms / 1000;
   bool bypass = InpCopyExisting && InBaseline(m.ticket);
   if(!bypass && InpMaxSignalAgeSec > 0 && age > InpMaxSignalAgeSec)
     { MarkSkip(m, StringFormat("opened %I64d s ago (> InpMaxSignalAgeSec)", age)); return; }
   if(g_loss_blocked) return;
   if(g_copies >= InpMaxCopies) { LogError("InpMaxCopies reached - not opening new copies"); return; }

   string sym = ResolveSymbol(m.symbol);
   if(sym == "") { MarkSkip(m, "symbol not found on this account"); return; }
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0) { SetCool("O", m.ticket, 1000); return; }

   int stype = SlaveType(m.type);
   double price = stype == POSITION_TYPE_BUY ? tick.ask : tick.bid;
   if(!bypass && InpMaxDeviationPts > 0)
     {
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      double adverse = (stype == POSITION_TYPE_BUY ? price - m.open : m.open - price) / point;
      if(adverse > InpMaxDeviationPts)
        {
         g_last_err = StringFormat("waiting on master #%I64u: price %.0f points worse than master entry", m.ticket, adverse);
         if(!Cooling("W", m.ticket)) { Print("JBCS: ", g_last_err); SetCool("W", m.ticket, 30000); }
         SetCool("O", m.ticket, 1000);
         return;
        }
     }

   double lots = CalcLots(m, sym);
   if(lots <= 0) { MarkSkip(m, "lot size below the broker minimum"); return; }
   double sl, tp;
   DesiredStops(m, sym, price, sl, tp);
   string comment = InpCommentPrefix + IntegerToString((long)m.ticket);
   ENUM_ORDER_TYPE ot = stype == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   g_trade.SetTypeFillingBySymbol(sym);
   bool ok = g_trade.PositionOpen(sym, ot, lots, price, sl, tp, comment);
   uint rc = g_trade.ResultRetcode();
   if(!(ok && Succeeded(rc)) && rc == TRADE_RETCODE_INVALID_STOPS && (sl > 0 || tp > 0))
     {
      LogError(StringFormat("master #%I64u: SL/TP rejected at entry, opening without and retrying them", m.ticket));
      ok = g_trade.PositionOpen(sym, ot, lots, price, 0, 0, comment);
      rc = g_trade.ResultRetcode();
     }
   if(ok && Succeeded(rc))
     {
      GvSet("H", m.ticket, 1);
      GvSet("R", m.ticket, lots / m.volume);
      GvSet("V", m.ticket, m.volume);
      if(g_trade.ResultOrder() > 0) GvSet("P", g_trade.ResultOrder(), (double)m.ticket);
      SetCool("M", m.ticket, 2000);
      g_copies++;
      Action(StringFormat("OPEN %s %s %s @ %s copy of master #%I64u (%s %s @ %s, %I64d s old)",
                          Side(stype), DoubleToString(lots, 2), sym,
                          DoubleToString(g_trade.ResultPrice(), (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                          m.ticket, Side(m.type), DoubleToString(m.volume, 2), DoubleToString(m.open, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)), age));
     }
   else
     {
      SetCool("O", m.ticket, 3000);
      LogError(StringFormat("open copy of master #%I64u failed: %u %s", m.ticket, rc, g_trade.ResultRetcodeDescription()));
     }
  }

void SyncVolume(const MPos &m, CPos &c[], const int &idx[], const int n)
  {
   string sym = c[idx[0]].symbol;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double cur = 0;
   for(int k = 0; k < n; k++) cur += c[idx[k]].volume;

   double ratio = GvGet("R", m.ticket, 0);
   if(ratio <= 0) { ratio = cur / m.volume; GvSet("R", m.ticket, ratio); }   // lost state: accept what we hold
   double last_v = GvGet("V", m.ticket, m.volume);
   double target = LotsDown(sym, m.volume * ratio);
   if(target < vmin) target = vmin;   // keep the minimum until the master closes

   if(cur - target > step * 0.5)
     {
      double left = cur - target;
      // newest copies first
      for(int pass = 0; pass < n && left > step * 0.5; pass++)
        {
         int best = -1;
         for(int k = 0; k < n; k++)
            if(c[idx[k]].volume > 0 && (best < 0 || c[idx[k]].time_msc > c[idx[best]].time_msc)) best = k;
         if(best < 0) break;
         CPos p = c[idx[best]];
         c[idx[best]].volume = 0;
         double take = MathMin(p.volume, left);
         if(p.volume - take > 0 && p.volume - take < vmin) take = p.volume - vmin;
         take = LotsDown(sym, take);
         if(take < step * 0.5) continue;
         g_trade.SetTypeFillingBySymbol(sym);
         bool full = take >= p.volume - step * 0.5;
         bool ok = full ? g_trade.PositionClose(p.ticket) : g_trade.PositionClosePartial(p.ticket, take);
         uint rc = g_trade.ResultRetcode();
         if(ok && Succeeded(rc))
           {
            Action(StringFormat("REDUCE %s %s by %s #%I64u (master #%I64u now %s lots)", Side(p.type), sym,
                                DoubleToString(take, 2), p.ticket, m.ticket, DoubleToString(m.volume, 2)));
            left -= take;
           }
         else
           {
            LogError(StringFormat("reduce #%I64u failed: %u %s", p.ticket, rc, g_trade.ResultRetcodeDescription()));
            break;
           }
        }
      SetCool("M", m.ticket, 2000);
     }
   else if(InpCopyAddOns && m.volume > last_v + 1e-9 && target - cur > step * 0.5)
     {
      double add = LotsDown(sym, target - cur);
      int stype = SlaveType(m.type);
      MqlTick tick;
      if(add >= vmin && SymbolInfoTick(sym, tick))
        {
         double sl, tp;
         double price = stype == POSITION_TYPE_BUY ? tick.ask : tick.bid;
         DesiredStops(m, sym, price, sl, tp);
         g_trade.SetTypeFillingBySymbol(sym);
         bool ok = g_trade.PositionOpen(sym, stype == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, add, price, sl, tp,
                                        InpCommentPrefix + IntegerToString((long)m.ticket));
         if(ok && Succeeded(g_trade.ResultRetcode()))
           {
            if(g_trade.ResultOrder() > 0) GvSet("P", g_trade.ResultOrder(), (double)m.ticket);
            Action(StringFormat("ADD %s %s %s (master #%I64u grew to %s lots)", Side(stype), DoubleToString(add, 2), sym,
                                m.ticket, DoubleToString(m.volume, 2)));
           }
         else
            LogError(StringFormat("add-on for master #%I64u failed: %u %s", m.ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
        }
      SetCool("M", m.ticket, 2000);
     }
   if(MathAbs(m.volume - last_v) > 1e-9) GvSet("V", m.ticket, m.volume);
  }

void SyncStops(const MPos &m, const CPos &c[], const int &idx[], const int n)
  {
   if(!InpCopySLTP) return;
   for(int k = 0; k < n; k++)
     {
      CPos p = c[idx[k]];
      if(p.volume <= 0 || Cooling("S", p.ticket)) continue;
      double sl, tp;
      DesiredStops(m, p.symbol, p.open, sl, tp);
      double half = SymbolInfoDouble(p.symbol, SYMBOL_POINT) * 0.5;
      if(MathAbs(sl - p.sl) <= half && MathAbs(tp - p.tp) <= half) continue;
      if(g_trade.PositionModify(p.ticket, sl, tp) && Succeeded(g_trade.ResultRetcode()))
        {
         Action(StringFormat("MODIFY #%I64u %s SL %s TP %s (master #%I64u)", p.ticket, p.symbol,
                             DoubleToString(sl, (int)SymbolInfoInteger(p.symbol, SYMBOL_DIGITS)),
                             DoubleToString(tp, (int)SymbolInfoInteger(p.symbol, SYMBOL_DIGITS)), m.ticket));
         SetCool("S", p.ticket, 1500);
        }
      else
        {
         SetCool("S", p.ticket, 5000);
         LogError(StringFormat("SL/TP update #%I64u failed: %u %s", p.ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
        }
     }
  }

//+------------------------------------------------------------------+
//| reconcile this account against the master book                   |
//+------------------------------------------------------------------+
void Reconcile(void)
  {
   g_last_err = "";   // the dashboard shows current problems only; the Experts log keeps the history
   bool same = g_m_login == AccountInfoInteger(ACCOUNT_LOGIN) && g_m_server == AccountInfoString(ACCOUNT_SERVER);
   if(same && !g_warned_same)
     {
      PrintFormat("JBCS: master and slave are the same account - master positions with magic %I64d are ignored; "
                  "set InpMagicExclude=%I64d on the master", InpMagic, InpMagic);
      g_warned_same = true;
     }
   if(!g_baseline_done)
     {
      ArrayResize(g_baseline, ArraySize(g_m));
      for(int i = 0; i < ArraySize(g_m); i++) g_baseline[i] = g_m[i].ticket;
      g_baseline_done = true;
      PrintFormat("JBCS: first master snapshot - %d position(s) open on master %I64d", ArraySize(g_m), g_m_login);
     }

   CPos c[];
   int nc = CollectCopies(c);

   //--- 1. copies whose master position is gone or flipped
   for(int k = 0; k < nc; k++)
     {
      int mi = FindMaster(c[k].master);
      if(mi < 0)
         CloseCopy(c[k], "master closed");
      else if(c[k].type != SlaveType(g_m[mi].type))
         CloseCopy(c[k], "master reversed");
     }
   nc = CollectCopies(c);

   //--- 2. master positions
   int idx[];
   for(int i = 0; i < ArraySize(g_m); i++)
     {
      if(same && g_m[i].magic == InpMagic) continue;   // never copy our own copies
      int n = 0;
      ArrayResize(idx, nc);
      for(int k = 0; k < nc; k++) if(c[k].master == g_m[i].ticket) idx[n++] = k;
      if(n == 0)
        {
         bool wanted = (ArraySize(g_sym_allow) == 0 || InStrings(g_m[i].symbol, g_sym_allow)) &&
                       (ArraySize(g_magic_allow) == 0 || InLongs(g_m[i].magic, g_magic_allow));
         if(wanted) TryOpen(g_m[i]);
         continue;
        }
      if(Cooling("M", g_m[i].ticket)) continue;
      SyncVolume(g_m[i], c, idx, n);
      SyncStops(g_m[i], c, idx, n);
     }
   if(g_gv_dirty) { GlobalVariablesFlush(); g_gv_dirty = false; }
  }

void UpdateLossGuard(void)
  {
   if(InpDailyLossLimit <= 0) { g_loss_blocked = false; return; }
   datetime now = TimeCurrent();
   datetime day = now - now % 86400;
   double pl = g_floating;
   if(HistorySelect(day, now + 86400))
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
         pl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
        }
   g_day_pl = pl;
   bool was = g_loss_blocked;
   g_loss_blocked = pl <= -InpDailyLossLimit;
   if(g_loss_blocked != was)
      PrintFormat("JBCS: daily loss limit %s (day P/L %.2f)", g_loss_blocked ? "HIT - no new copies today" : "cleared", pl);
  }

void CleanupGlobals(const CPos &c[])
  {
   string names[];
   int total = GlobalVariablesTotal();
   for(int i = 0; i < total; i++)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, g_gv) != 0) continue;
      string rest = StringSubstr(name, StringLen(g_gv));
      string kind = StringSubstr(rest, 0, 1);
      ulong id = (ulong)StringToInteger(StringSubstr(rest, 2));
      bool stale = kind == "P" ? !PositionSelectByTicket(id) : (FindMaster(id) < 0 && !HasCopy(c, id));
      if(stale)
        {
         int n = ArraySize(names);
         ArrayResize(names, n + 1);
         names[n] = name;
        }
     }
   for(int i = 0; i < ArraySize(names); i++) GlobalVariableDel(names[i]);
   if(ArraySize(names) > 0) GlobalVariablesFlush();
   PruneCool();
  }

void ShowStatus(void)
  {
   static ulong last = 0;
   ulong now = GetTickCount64();
   if(now - last < 500) return;
   last = now;
   string master = g_have_snapshot
                   ? StringFormat("master %I64d  balance %.2f %s  |  %d position(s)  |  seq %I64d  |  age %.1fs",
                                  g_m_login, g_m_balance, g_m_currency, ArraySize(g_m), g_seq,
                                  (g_age_ms + (long)(now - g_rx_ms)) / 1000.0)
                   : "no master snapshot yet";
   string lots = StringFormat("%s x%.2f%s", EnumToString(InpLotMode), InpLotValue, InpReverse ? "  REVERSE" : "");
   Comment(StringFormat("JB Copier SLAVE v%s  |  %s\nchannel %s @ %s\n%s\ncopies %d  floating %.2f  |  %s%s%s%s",
                        SLAVE_VERSION, g_state, InpChannel, g_http.BaseUrl(), master, g_copies, g_floating, lots,
                        InpDailyLossLimit > 0 ? StringFormat("  |  day P/L %.2f", g_day_pl) : "",
                        g_last_action != "" ? "\nlast action: " + g_last_action : "",
                        g_last_err != "" ? "\nlast error: " + g_last_err : ""));
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSlaveKey == "")
     {
      Alert("JB Copier slave: set InpSlaveKey (see copy_server.json)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpChannel == "" || StringFind(InpChannel, "/") >= 0 || InpMagic <= 0 || InpLotValue <= 0)
      return INIT_PARAMETERS_INCORRECT;
   if(!g_http.Init(InpTransport, InpServerUrl, InpSlaveKey))
     {
      Alert("JB Copier slave: ", g_http.error);
      return INIT_PARAMETERS_INCORRECT;
     }
   string pairs[];
   SplitList(InpSymbolMap, pairs);
   for(int i = 0; i < ArraySize(pairs); i++)
     {
      int eq = StringFind(pairs[i], "=");
      if(eq <= 0) { Alert("JB Copier slave: bad InpSymbolMap entry ", pairs[i]); return INIT_PARAMETERS_INCORRECT; }
      int n = ArraySize(g_map_from);
      ArrayResize(g_map_from, n + 1);
      ArrayResize(g_map_to, n + 1);
      g_map_from[n] = Trimmed(StringSubstr(pairs[i], 0, eq));
      g_map_to[n]   = Trimmed(StringSubstr(pairs[i], eq + 1));
     }
   if(!IsAll(InpSymbolsAllow)) SplitList(InpSymbolsAllow, g_sym_allow);
   string mags[];
   if(!IsAll(InpMagicAllow)) SplitList(InpMagicAllow, mags);
   for(int i = 0; i < ArraySize(mags); i++)
     {
      if(StringToInteger(mags[i]) == 0 && mags[i] != "0") { Print("JBCS: '", mags[i], "' is not a magic number - ignored"); continue; }
      int n = ArraySize(g_magic_allow);
      ArrayResize(g_magic_allow, n + 1);
      g_magic_allow[n] = StringToInteger(mags[i]);
     }

   g_gv = StringFormat("JBCS.%I64d.", InpMagic);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   PrintFormat("JBCS v%s: channel '%s' <- %s via %s, lots %s x%.2f, max age %d s, max deviation %d pts, magic %I64d%s",
               SLAVE_VERSION, InpChannel, g_http.BaseUrl(), EnumToString(InpTransport), EnumToString(InpLotMode),
               InpLotValue, InpMaxSignalAgeSec, InpMaxDeviationPts, InpMagic, InpReverse ? ", REVERSE" : "");
   EventSetMillisecondTimer(MathMax(20, InpPollMs));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   GlobalVariablesFlush();
   g_http.Close();
   Comment("");
  }

void OnTick() {}

void OnTimer()
  {
   ulong now = GetTickCount64();
   bool connected = (TerminalInfoInteger(TERMINAL_CONNECTED) || MQLInfoInteger(MQL_TESTER)) && AccountInfoDouble(ACCOUNT_BALANCE) > 0;
   if(connected && !g_hedging_checked)
     {
      g_hedging = AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
      g_hedging_checked = true;
      if(!g_hedging) Alert("JB Copier slave needs a HEDGING account - copying is disabled on this netting account");
     }
   if(g_id == "" && connected)
     {
      string id = InpSlaveId != "" ? InpSlaveId : IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
      for(int i = 0; i < StringLen(id); i++)
        {
         ushort ch = StringGetCharacter(id, i);
         bool ok = (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '-' || ch == '_' || ch == '.';
         if(!ok) StringSetCharacter(id, i, '_');
        }
      g_id = id;
     }
   if(g_id == "") { g_state = "waiting for broker connection"; ShowStatus(); return; }

   bool polled = Poll();
   if(now - g_last_loss_ms > 5000) { UpdateLossGuard(); g_last_loss_ms = now; }

   if(!g_hedging)
      g_state = "NETTING ACCOUNT - NOT SUPPORTED";
   else if(!polled && !MasterFresh())
      g_state = "SERVER UNREACHABLE - frozen";
   else if(!MasterFresh())
      g_state = g_have_snapshot ? "MASTER OFFLINE - frozen" : "waiting for master";
   else if(!connected)
      g_state = "BROKER DISCONNECTED";
   else if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
           !AccountInfoInteger(ACCOUNT_TRADE_EXPERT) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      g_state = "ALGO TRADING DISABLED";
   else
     {
      g_state = g_loss_blocked ? "DAILY LOSS LIMIT - managing only" : "COPYING";
      Reconcile();
      if(now - g_last_gc_ms > 60000)
        {
         CPos c[];
         CollectCopies(c);
         CleanupGlobals(c);
         g_last_gc_ms = now;
        }
     }
   if(now - g_last_status_ms > 3000) { SendStatus(); g_last_status_ms = GetTickCount64(); }
   ShowStatus();
  }
//+------------------------------------------------------------------+
