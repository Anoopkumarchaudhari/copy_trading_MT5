//+------------------------------------------------------------------+
//|                                                JB_CopyMaster.mq5 |
//|  JB Copier - MASTER side.                                        |
//|  Publishes this account's open positions to the JB Copier relay  |
//|  server (docs\jb_copier\server\copy_server.py). Opens no trades. |
//|                                                                  |
//|  Snapshot sent to POST /v1/<channel>/push:                       |
//|   A|login|server|currency|balance|equity|leverage|server_time|ver |
//|   P|ticket|symbol|type|volume|open|sl|tp|magic|time|contract|digits
//|  Pushed at once when positions or balance change, otherwise every|
//|  InpHeartbeatSec as a heartbeat. Nothing is pushed while the     |
//|  terminal is disconnected or still synchronising, so slaves see  |
//|  "master offline" (and freeze) instead of an empty book.         |
//+------------------------------------------------------------------+
#property copyright "JB"
#property version   "1.01"
#property description "JB Copier master: publishes open positions to the JB Copier relay server."

#include "JB_CopierNet.mqh"

#define MASTER_VERSION "1.01"

input group "Server"
input string                InpServerUrl    = "http://127.0.0.1:8787"; // Relay server URL
input string                InpChannel      = "main";                  // Channel name
input string                InpMasterKey    = "";                      // Master key (copy_server.json)
input ENUM_COPIER_TRANSPORT InpTransport    = TRANSPORT_WEBREQUEST;    // Transport
input int                   InpTimeoutMs    = 3000;                    // HTTP timeout, ms

input group "Publishing"
input int                   InpScanMs       = 200;   // Scan interval, ms
input int                   InpHeartbeatSec = 2;     // Resend an unchanged snapshot every N s
input int                   InpSettleSec    = 3;     // Wait after (re)connect before publishing, s
input string                InpMagicInclude = "";    // Publish only these magics ("" or all = all, 0 = manual)
input string                InpMagicExclude = "";    // Never publish these magics (slave on same account)
input string                InpSymbols      = "";    // Publish only these symbols ("" or all = all)

CCopierHttp g_http;
long        g_inc[], g_exc[];
string      g_syms[];
string      g_last_book = "";      // positions + balance of the last successful push
ulong       g_last_push_ms = 0;    // GetTickCount64 of the last successful push
ulong       g_next_try_ms = 0;     // back-off after a failed push
int         g_fail = 0;
long        g_seq = 0;
ulong       g_connected_since = 0; // 0 = disconnected
string      g_state = "starting";
int         g_npos = 0;
ulong       g_pushes = 0;
string      g_last_err = "";
ulong       g_last_err_log = 0;

//+------------------------------------------------------------------+
//| "all" / "*" / "" = no filter                                     |
//+------------------------------------------------------------------+
bool IsAll(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   StringToLower(s);
   return s == "" || s == "all" || s == "*";
  }

int SplitLongs(const string list, long &out[])
  {
   ArrayResize(out, 0);
   if(IsAll(list)) return 0;
   string parts[];
   int n = StringSplit(list, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p == "") continue;
      if(StringToInteger(p) == 0 && p != "0") { Print("JBCM: '", p, "' is not a magic number - ignored"); continue; }
      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = StringToInteger(p);
     }
   return ArraySize(out);
  }

int SplitStrings(const string list, string &out[])
  {
   ArrayResize(out, 0);
   if(IsAll(list)) return 0;
   string parts[];
   int n = StringSplit(list, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p == "") continue;
      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = p;
     }
   return ArraySize(out);
  }

bool InLongs(const long v, const long &a[])
  {
   for(int i = 0; i < ArraySize(a); i++) if(a[i] == v) return true;
   return false;
  }

bool InStrings(const string v, const string &a[])
  {
   for(int i = 0; i < ArraySize(a); i++) if(a[i] == v) return true;
   return false;
  }

void LogError(const string msg)
  {
   g_last_err = msg;
   ulong now = GetTickCount64();
   if(now - g_last_err_log > 30000) { Print("JBCM: ", msg); g_last_err_log = now; }
  }

string Num(const double v, const int digits)
  {
   string s = DoubleToString(v, digits);
   if(StringFind(s, ".") >= 0)
     {
      while(StringGetCharacter(s, StringLen(s) - 1) == '0') s = StringSubstr(s, 0, StringLen(s) - 1);
      if(StringGetCharacter(s, StringLen(s) - 1) == '.') s = StringSubstr(s, 0, StringLen(s) - 1);
     }
   return s;
  }

//+------------------------------------------------------------------+
//| Positions part of the snapshot (also used as the change digest). |
//+------------------------------------------------------------------+
string BuildBook(int &count)
  {
   string book = "";
   count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long   magic = PositionGetInteger(POSITION_MAGIC);
      string sym   = PositionGetString(POSITION_SYMBOL);
      if(ArraySize(g_inc) > 0 && !InLongs(magic, g_inc)) continue;
      if(InLongs(magic, g_exc)) continue;
      if(ArraySize(g_syms) > 0 && !InStrings(sym, g_syms)) continue;
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      book += StringFormat("P|%I64u|%s|%d|%s|%s|%s|%s|%I64d|%I64d|%s|%d\n",
                           ticket, sym, (int)PositionGetInteger(POSITION_TYPE),
                           Num(PositionGetDouble(POSITION_VOLUME), 8),
                           DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits),
                           DoubleToString(PositionGetDouble(POSITION_SL), digits),
                           DoubleToString(PositionGetDouble(POSITION_TP), digits),
                           magic, (long)PositionGetInteger(POSITION_TIME),
                           Num(SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE), 8), digits);
      count++;
     }
   return book;
  }

bool Ready(void)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoDouble(ACCOUNT_BALANCE) <= 0)
     {
      g_connected_since = 0;
      g_state = "waiting for broker connection";
      return false;
     }
   ulong now = GetTickCount64();
   if(g_connected_since == 0) g_connected_since = now;
   if(now - g_connected_since < (ulong)InpSettleSec * 1000)
     {
      g_state = "synchronising";
      return false;
     }
   return true;
  }

void Scan(const bool force)
  {
   if(!Ready()) { ShowStatus(); return; }
   ulong now = GetTickCount64();
   if(now < g_next_try_ms) return;

   int count;
   string book = BuildBook(count);
   g_npos = count;
   string digest = book + Num(AccountInfoDouble(ACCOUNT_BALANCE), 2);
   bool changed = digest != g_last_book;
   if(!changed && !force && now - g_last_push_ms < (ulong)InpHeartbeatSec * 1000)
     {
      ShowStatus();
      return;
     }

   string head = StringFormat("A|%I64d|%s|%s|%s|%s|%I64d|%I64d|%s\n",
                              AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                              AccountInfoString(ACCOUNT_CURRENCY),
                              Num(AccountInfoDouble(ACCOUNT_BALANCE), 2), Num(AccountInfoDouble(ACCOUNT_EQUITY), 2),
                              AccountInfoInteger(ACCOUNT_LEVERAGE), (long)TimeTradeServer(), MASTER_VERSION);
   string resp;
   int status;
   bool ok = g_http.Request("POST", "/v1/" + InpChannel + "/push", head + book, resp, status, InpTimeoutMs);
   if(ok && status == 200 && StringFind(resp, "OK|") == 0)
     {
      g_seq = StringToInteger(StringSubstr(resp, 3));
      g_last_book = digest;
      g_last_push_ms = now;
      g_pushes++;
      if(g_fail > 0) Print("JBCM: server reachable again, seq ", g_seq);
      g_fail = 0;
      g_last_err = "";
      g_state = "LIVE";
      if(changed) Print(StringFormat("JBCM: published %d position(s), seq %I64d", count, g_seq));
     }
   else
     {
      g_fail++;
      g_next_try_ms = now + (ulong)MathMin(5000, 250 * (1 << MathMin(g_fail, 5)));
      if(!ok)
         LogError("push failed: " + g_http.error);
      else if(status == 403)
         LogError("push rejected: wrong master key or channel");
      else
         LogError(StringFormat("push failed: HTTP %d %s", status, resp));
      g_state = "SERVER UNREACHABLE";
     }
   ShowStatus();
  }

void ShowStatus(void)
  {
   static ulong last = 0;
   ulong now = GetTickCount64();
   if(now - last < 500) return;
   last = now;
   string age = g_last_push_ms > 0 ? StringFormat("%.1fs ago", (now - g_last_push_ms) / 1000.0) : "never";
   Comment(StringFormat("JB Copier MASTER v%s  |  %s\nchannel %s  @ %s\npositions published %d  |  seq %I64d  |  last push %s  |  pushes %I64u%s",
                        MASTER_VERSION, g_state, InpChannel, g_http.BaseUrl(), g_npos, g_seq, age, g_pushes,
                        g_last_err != "" ? "\nlast error: " + g_last_err : ""));
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMasterKey == "")
     {
      Alert("JB Copier master: set InpMasterKey (see copy_server.json)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(StringFind(InpChannel, "/") >= 0 || InpChannel == "")
      return INIT_PARAMETERS_INCORRECT;
   if(!g_http.Init(InpTransport, InpServerUrl, InpMasterKey))
     {
      Alert("JB Copier master: ", g_http.error);
      return INIT_PARAMETERS_INCORRECT;
     }
   SplitLongs(InpMagicInclude, g_inc);
   SplitLongs(InpMagicExclude, g_exc);
   SplitStrings(InpSymbols, g_syms);
   PrintFormat("JBCM v%s: channel '%s' -> %s via %s, scan %d ms, heartbeat %d s, magic include [%s] exclude [%s]",
               MASTER_VERSION, InpChannel, g_http.BaseUrl(), EnumToString(InpTransport), InpScanMs,
               InpHeartbeatSec, InpMagicInclude, InpMagicExclude);
   EventSetMillisecondTimer(MathMax(50, InpScanMs));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_http.Close();
   Comment("");
   // Deliberately no "flat" push: removing the master must freeze the slaves, not close them.
  }

void OnTimer()       { Scan(false); }
void OnTick()        {}
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_POSITION)
      Scan(false);
  }
//+------------------------------------------------------------------+
