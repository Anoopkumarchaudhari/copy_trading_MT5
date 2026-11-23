//+------------------------------------------------------------------+
//|                                                    CopierNet.mqh |
//|  HTTP transport shared by CopyMaster and CopySlave.              |
//|  WEBREQUEST : MQL5 WebRequest - the server URL must be added in  |
//|               Tools > Options > Expert Advisors > Allow WebRequest|
//|  WININET    : Windows wininet.dll - no URL list, but the EA needs|
//|               "Allow DLL imports"; keeps the connection alive.   |
//+------------------------------------------------------------------+
#property strict

enum ENUM_COPIER_TRANSPORT
  {
   TRANSPORT_WEBREQUEST = 0, // WebRequest (URL in Options > Expert Advisors)
   TRANSPORT_WININET    = 1  // WinINet DLL (Allow DLL imports, no URL list)
  };

#import "wininet.dll"
long InternetOpenW(string agent, uint access_type, long proxy, long proxy_bypass, uint flags);
long InternetConnectW(long internet, string server, int port, long user, long password, uint service, uint flags, long context);
long HttpOpenRequestW(long connect, string verb, string object, string version, long referrer, long accept_types, uint flags, long context);
int  HttpSendRequestW(long request, string headers, int headers_len, uchar &optional[], int optional_len);
int  HttpQueryInfoW(long request, uint info_level, int &buffer, int &buffer_len, int &index);
int  InternetReadFile(long file, uchar &buffer[], int to_read, int &read);
int  InternetSetOptionW(long internet, uint option, int &buffer, int buffer_len);
int  InternetCloseHandle(long internet);
#import
#import "kernel32.dll"
int  GetLastError(void);
#import

#define WININET_OPEN_DIRECT         1
#define WININET_SERVICE_HTTP        3
#define WININET_OPT_CONNECT_TIMEOUT 2
#define WININET_OPT_SEND_TIMEOUT    5
#define WININET_OPT_RECEIVE_TIMEOUT 6
#define WININET_QUERY_STATUS_NUMBER 0x20000013   // HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER
#define WININET_REQUEST_FLAGS       0x84400100   // RELOAD | NO_CACHE_WRITE | KEEP_CONNECTION | PRAGMA_NOCACHE
#define WININET_FLAG_SECURE         0x00800000

//+------------------------------------------------------------------+
class CCopierHttp
  {
private:
   ENUM_COPIER_TRANSPORT m_transport;
   string            m_base;      // scheme://host:port/prefix without trailing slash
   string            m_host;
   int               m_port;
   bool              m_https;
   string            m_prefix;    // path prefix taken from the URL ("" or "/copier")
   string            m_key;
   long              m_session;
   long              m_connect;

   bool              ParseUrl(string url);
   bool              SendWebRequest(const string method, const string path, const string body,
                                    string &response, int &status, const int timeout_ms);
   bool              SendWinInet(const string method, const string path, const string body,
                                 string &response, int &status, const int timeout_ms);
public:
   string            error;       // text of the last failure ("" after a success)

                     CCopierHttp(void) : m_session(0), m_connect(0), m_port(80), m_https(false) {}
                    ~CCopierHttp(void) { Close(); }
   bool              Init(const ENUM_COPIER_TRANSPORT transport, const string url, const string key);
   void              Close(void);
   string            BaseUrl(void) const { return m_base; }
   //--- true when the server answered (any HTTP status); response/status filled in
   bool              Request(const string method, const string path, const string body,
                             string &response, int &status, const int timeout_ms);
  };

//+------------------------------------------------------------------+
bool CCopierHttp::Init(const ENUM_COPIER_TRANSPORT transport, const string url, const string key)
  {
   Close();
   m_transport = transport;
   m_key = key;
   return ParseUrl(url);
  }

void CCopierHttp::Close(void)
  {
   if(m_connect != 0) { InternetCloseHandle(m_connect); m_connect = 0; }
   if(m_session != 0) { InternetCloseHandle(m_session); m_session = 0; }
  }

bool CCopierHttp::ParseUrl(string url)
  {
   StringTrimLeft(url);
   StringTrimRight(url);
   while(StringLen(url) > 0 && StringGetCharacter(url, StringLen(url) - 1) == '/')
      url = StringSubstr(url, 0, StringLen(url) - 1);
   string low = url;
   StringToLower(low);
   int skip;
   if(StringFind(low, "https://") == 0)      { m_https = true;  m_port = 443; skip = 8; }
   else if(StringFind(low, "http://") == 0)  { m_https = false; m_port = 80;  skip = 7; }
   else { error = "server URL must start with http:// or https://"; return false; }

   string rest = StringSubstr(url, skip);
   int slash = StringFind(rest, "/");
   string hostport = (slash < 0) ? rest : StringSubstr(rest, 0, slash);
   m_prefix = (slash < 0) ? "" : StringSubstr(rest, slash);
   int colon = StringFind(hostport, ":");
   m_host = (colon < 0) ? hostport : StringSubstr(hostport, 0, colon);
   if(colon >= 0)
      m_port = (int)StringToInteger(StringSubstr(hostport, colon + 1));
   if(m_host == "" || m_port <= 0 || m_port > 65535) { error = "bad server URL: " + url; return false; }
   m_base = url;
   error = "";
   return true;
  }

bool CCopierHttp::Request(const string method, const string path, const string body,
                          string &response, int &status, const int timeout_ms)
  {
   response = "";
   status = 0;
   bool ok = (m_transport == TRANSPORT_WININET)
             ? SendWinInet(method, path, body, response, status, timeout_ms)
             : SendWebRequest(method, path, body, response, status, timeout_ms);
   if(ok)
      error = "";
   return ok;
  }

bool CCopierHttp::SendWebRequest(const string method, const string path, const string body,
                                 string &response, int &status, const int timeout_ms)
  {
   char data[], result[];
   string result_headers;
   int n = StringLen(body) > 0 ? StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1 : 0;
   ArrayResize(data, MathMax(n, 0));
   string headers = "X-Key: " + m_key + "\r\nContent-Type: text/plain\r\n";
   ResetLastError();
   status = WebRequest(method, m_base + path, headers, timeout_ms, data, result, result_headers);
   if(status == -1)
     {
      int err = ::GetLastError();
      if(err == 4014)
         error = "WebRequest not allowed - add " + m_base + " in Tools > Options > Expert Advisors";
      else if(err == 5202)
         error = "timeout";
      else
         error = StringFormat("WebRequest error %d", err);
      return false;
     }
   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
  }

bool CCopierHttp::SendWinInet(const string method, const string path, const string body,
                              string &response, int &status, const int timeout_ms)
  {
   if(m_session == 0)
     {
      m_session = InternetOpenW("MT5Copier", WININET_OPEN_DIRECT, 0, 0, 0);
      if(m_session == 0) { error = StringFormat("InternetOpen failed (%d) - is Allow DLL imports on?", kernel32::GetLastError()); return false; }
      int ct = 5000;
      InternetSetOptionW(m_session, WININET_OPT_CONNECT_TIMEOUT, ct, 4);
     }
   if(m_connect == 0)
     {
      m_connect = InternetConnectW(m_session, m_host, m_port, 0, 0, WININET_SERVICE_HTTP, 0, 0);
      if(m_connect == 0) { error = StringFormat("InternetConnect failed (%d)", kernel32::GetLastError()); Close(); return false; }
     }
   uint flags = WININET_REQUEST_FLAGS | (m_https ? WININET_FLAG_SECURE : 0);
   long req = HttpOpenRequestW(m_connect, method, m_prefix + path, "HTTP/1.1", 0, 0, flags, 0);
   if(req == 0) { error = StringFormat("HttpOpenRequest failed (%d)", kernel32::GetLastError()); Close(); return false; }

   int t = timeout_ms;
   InternetSetOptionW(req, WININET_OPT_SEND_TIMEOUT, t, 4);
   InternetSetOptionW(req, WININET_OPT_RECEIVE_TIMEOUT, t, 4);

   uchar data[];
   int n = StringLen(body) > 0 ? StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1 : 0;
   if(n < 0) n = 0;
   ArrayResize(data, MathMax(n, 1));
   string headers = "X-Key: " + m_key + "\r\nContent-Type: text/plain\r\n";
   if(HttpSendRequestW(req, headers, -1, data, n) == 0)
     {
      int err = kernel32::GetLastError();
      error = (err == 12002) ? "timeout" : StringFormat("HttpSendRequest failed (%d)", err);
      InternetCloseHandle(req);
      Close();
      return false;
     }
   int code = 0, len = 4, idx = 0;
   HttpQueryInfoW(req, WININET_QUERY_STATUS_NUMBER, code, len, idx);
   status = code;

   uchar all[], chunk[];
   ArrayResize(chunk, 4096);
   int got = 0, total = 0;
   while(InternetReadFile(req, chunk, 4096, got) != 0 && got > 0)
     {
      ArrayResize(all, total + got);
      ArrayCopy(all, chunk, total, 0, got);
      total += got;
     }
   InternetCloseHandle(req);
   response = total > 0 ? CharArrayToString(all, 0, total, CP_UTF8) : "";
   return true;
  }
//+------------------------------------------------------------------+
