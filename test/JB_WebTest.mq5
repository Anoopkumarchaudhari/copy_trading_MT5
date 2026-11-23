// Probe: can a headless clone reach the relay with WebRequest?
#property version "1.00"
void OnStart()
  {
   string url = "http://127.0.0.1:8787/health";
   char   data[], result[];
   string headers;
   ResetLastError();
   int code = WebRequest("GET", url, "", 3000, data, result, headers);
   int err  = GetLastError();
   string txt = StringFormat("code=%d err=%d body=%s", code, err, CharArrayToString(result));
   Print("JBWEBTEST ", txt);
   int h = FileOpen("jbcopier_webtest.txt", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h != INVALID_HANDLE) { FileWriteString(h, txt); FileClose(h); }
   TerminalClose(0);
  }
