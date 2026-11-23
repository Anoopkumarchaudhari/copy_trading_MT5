//+------------------------------------------------------------------+
//|                                               CopyTestDriver.mq5 |
//|  Live-test driver for MT5 Copier (demo only). Plays a fixed      |
//|  scenario with magic InpMagic so CopyMaster (InpMagicInclude)    |
//|  publishes it, logs every step to Common\Files\copier_driver.txt,|
//|  then exports all deals of the driver and the slave magics to    |
//|  Common\Files\copier_deals.csv and removes itself.               |
//+------------------------------------------------------------------+
#property version "1.00"
#include <Trade\Trade.mqh>

input long   InpMagic      = 26101799;  // Driver (master-side) magic
input long   InpSlaveMagic = 26101701;  // Slave copy magic (for the export)
input string InpSym1       = "EURUSD";
input string InpSym2       = "GBPUSD";
input double InpLots       = 0.10;
input int    InpStartDelay = 25;        // seconds before the first step

CTrade   tr;
ulong    g_t0 = 0;
datetime g_start;
int      g_step = 0;
ulong    p1 = 0, p2 = 0, p3 = 0, p3b = 0, p4 = 0;

void Mark(const string what)
  {
   string line = StringFormat("%s|%.1f|%s", TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
                              (GetTickCount64() - g_t0) / 1000.0, what);
   Print("DRIVER ", line);
   int h = FileOpen("copier_driver.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI | FILE_SHARE_READ);
   if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWriteString(h, line + "\r\n"); FileClose(h); }
  }

double Pip(const string s) { return SymbolInfoDouble(s, SYMBOL_POINT) * 10; }

ulong Open(const string s, const ENUM_ORDER_TYPE t, const double lots, const double sl_pips, const double tp_pips)
  {
   MqlTick k;
   SymbolInfoTick(s, k);
   double px = t == ORDER_TYPE_BUY ? k.ask : k.bid, d = t == ORDER_TYPE_BUY ? 1 : -1;
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   double sl = sl_pips > 0 ? NormalizeDouble(px - d * sl_pips * Pip(s), dg) : 0;
   double tp = tp_pips > 0 ? NormalizeDouble(px + d * tp_pips * Pip(s), dg) : 0;
   tr.SetTypeFillingBySymbol(s);
   if(!tr.PositionOpen(s, t, lots, px, sl, tp, "copier-test"))
     { Mark(StringFormat("OPEN FAILED %s %u %s", s, tr.ResultRetcode(), tr.ResultRetcodeDescription())); return 0; }
   ulong pos = tr.ResultOrder();
   Mark(StringFormat("OPEN #%I64u %s %s %.2f @ %s SL %s TP %s", pos, t == ORDER_TYPE_BUY ? "BUY" : "SELL", s, lots,
                     DoubleToString(tr.ResultPrice(), dg), DoubleToString(sl, dg), DoubleToString(tp, dg)));
   return pos;
  }

void Modify(const ulong pos, const double sl_pips, const double tp_pips)
  {
   if(!PositionSelectByTicket(pos)) { Mark(StringFormat("MODIFY #%I64u: position gone", pos)); return; }
   string s = PositionGetString(POSITION_SYMBOL);
   double op = PositionGetDouble(POSITION_PRICE_OPEN), d = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   double sl = sl_pips > 0 ? NormalizeDouble(op - d * sl_pips * Pip(s), dg) : 0;
   double tp = tp_pips > 0 ? NormalizeDouble(op + d * tp_pips * Pip(s), dg) : 0;
   bool ok = tr.PositionModify(pos, sl, tp);
   Mark(StringFormat("MODIFY #%I64u SL %s TP %s %s", pos, DoubleToString(sl, dg), DoubleToString(tp, dg), ok ? "ok" : tr.ResultRetcodeDescription()));
  }

void Partial(const ulong pos, const double lots)
  {
   bool ok = tr.PositionClosePartial(pos, lots);
   Mark(StringFormat("PARTIAL #%I64u %.2f %s", pos, lots, ok ? "ok" : tr.ResultRetcodeDescription()));
  }

void Close(const ulong pos)
  {
   if(!PositionSelectByTicket(pos)) { Mark(StringFormat("CLOSE #%I64u: already gone", pos)); return; }
   bool ok = tr.PositionClose(pos);
   Mark(StringFormat("CLOSE #%I64u %s", pos, ok ? "ok" : tr.ResultRetcodeDescription()));
  }

void Export(void)
  {
   HistorySelect(g_start - 120, TimeCurrent() + 3600);
   int h = FileOpen("copier_deals.csv", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, "deal,time_msc,magic,symbol,type,entry,volume,price,position,comment,profit\r\n");
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      long mg = HistoryDealGetInteger(d, DEAL_MAGIC);
      if(mg != InpMagic && mg != InpSlaveMagic) continue;
      string s = HistoryDealGetString(d, DEAL_SYMBOL);
      FileWriteString(h, StringFormat("%I64u,%I64d,%I64d,%s,%d,%d,%.2f,%s,%I64d,%s,%.2f\r\n", d,
                                      HistoryDealGetInteger(d, DEAL_TIME_MSC), mg, s,
                                      (int)HistoryDealGetInteger(d, DEAL_TYPE), (int)HistoryDealGetInteger(d, DEAL_ENTRY),
                                      HistoryDealGetDouble(d, DEAL_VOLUME),
                                      DoubleToString(HistoryDealGetDouble(d, DEAL_PRICE), (int)SymbolInfoInteger(s, SYMBOL_DIGITS)),
                                      HistoryDealGetInteger(d, DEAL_POSITION_ID), HistoryDealGetString(d, DEAL_COMMENT),
                                      HistoryDealGetDouble(d, DEAL_PROFIT)));
     }
   FileClose(h);
   int open_driver = 0, open_slave = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg == InpMagic) open_driver++;
      if(mg == InpSlaveMagic) open_slave++;
     }
   Mark(StringFormat("EXPORTED deals; still open: driver %d, slave %d", open_driver, open_slave));
  }

int OnInit()
  {
   tr.SetExpertMagicNumber(InpMagic);
   tr.SetDeviationInPoints(30);
   g_t0 = GetTickCount64();
   g_start = TimeCurrent();
   FileDelete("copier_driver.txt", FILE_COMMON);
   Mark("driver started");
   EventSetTimer(1);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTick() {}

void OnTimer()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoDouble(ACCOUNT_BALANCE) <= 0) return;
   double t = (GetTickCount64() - g_t0) / 1000.0 - InpStartDelay;
   // phase 1: open / modify / partial / close
   if(g_step == 0 && t >= 0)   { g_start = TimeCurrent(); p1 = Open(InpSym1, ORDER_TYPE_BUY, InpLots, 30, 60); g_step++; }
   if(g_step == 1 && t >= 12)  { p2 = Open(InpSym2, ORDER_TYPE_SELL, InpLots, 30, 60); g_step++; }
   if(g_step == 2 && t >= 24)  { Modify(p1, 20, 40); g_step++; }
   if(g_step == 3 && t >= 36)  { Partial(p1, 0.04); g_step++; }
   if(g_step == 4 && t >= 48)  { Modify(p2, 30, 0); g_step++; }
   if(g_step == 5 && t >= 60)  { Close(p1); g_step++; }
   if(g_step == 6 && t >= 72)  { Close(p2); g_step++; }
   // phase 2: master outage (runner kills the master terminal at ~85 s, restarts at ~110 s)
   if(g_step == 7 && t >= 80)  { Mark("PHASE2"); p3 = Open(InpSym1, ORDER_TYPE_BUY, InpLots, 0, 0); g_step++; }
   if(g_step == 8 && t >= 98)  { p3b = Open(InpSym2, ORDER_TYPE_BUY, InpLots, 0, 0); g_step++; }   // while master is down
   if(g_step == 9 && t >= 140) { Close(p3); Close(p3b); g_step++; }
   // phase 3: slave restart (runner kills the slave at ~158 s, restarts at ~163 s)
   if(g_step == 10 && t >= 150) { Mark("PHASE3"); p4 = Open(InpSym1, ORDER_TYPE_SELL, InpLots, 40, 0); g_step++; }
   if(g_step == 11 && t >= 185) { Partial(p4, 0.05); g_step++; }
   if(g_step == 12 && t >= 200) { Close(p4); g_step++; }
   if(g_step == 13 && t >= 215) { Export(); Mark("DONE"); g_step++; ExpertRemove(); }
  }
//+------------------------------------------------------------------+
