// Lists symbols with a Saturday trade session and a fresh tick (weekend test candidates).
#property version "1.00"
void OnStart()
  {
   int h = FileOpen("copier_symscan.csv", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   FileWriteString(h, "symbol,path,digits,contract,vmin,vstep,stops,tick_age_s,bid,ask,spread_pts\r\n");
   string cand[];
   for(int i = 0; i < SymbolsTotal(false); i++)
     {
      string s = SymbolName(i, false);
      datetime f, t;
      if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) continue;
      if(!SymbolInfoSessionTrade(s, SATURDAY, 0, f, t)) continue;
      int n = ArraySize(cand); ArrayResize(cand, n + 1); cand[n] = s;
      SymbolSelect(s, true);
     }
   Sleep(8000);
   for(int i = 0; i < ArraySize(cand); i++)
     {
      string s = cand[i];
      MqlTick k;
      SymbolInfoTick(s, k);
      FileWriteString(h, StringFormat("%s,%s,%d,%.4f,%.4f,%.4f,%d,%I64d,%s,%s,%I64d\r\n", s, SymbolInfoString(s, SYMBOL_PATH),
                      (int)SymbolInfoInteger(s, SYMBOL_DIGITS), SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE),
                      SymbolInfoDouble(s, SYMBOL_VOLUME_MIN), SymbolInfoDouble(s, SYMBOL_VOLUME_STEP),
                      (int)SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL), (long)(TimeCurrent() - k.time),
                      DoubleToString(k.bid, 8), DoubleToString(k.ask, 8), SymbolInfoInteger(s, SYMBOL_SPREAD)));
     }
   FileClose(h);
   TerminalClose(0);
  }
