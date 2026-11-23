#!/usr/bin/env python3
"""MT5 Copier relay server.

The master EA pushes a snapshot of its open positions; slave EAs long-poll
for the newest snapshot and reconcile their own positions against it.
Standard library only, so it runs on any VPS with Python 3.8+.

    python copy_server.py                       # first run writes copy_server.json with fresh keys
    python copy_server.py --host 0.0.0.0 --port 8787 --config copy_server.json
    python copy_server.py --cert fullchain.pem --key privkey.pem   # HTTPS

Endpoints (all keys go in the X-Key header):
    POST /v1/<channel>/push              master key   body = snapshot lines (A|... / P|...)
    GET  /v1/<channel>/pull?id=&seq=&boot=&wait=  slave key  long-poll; returns "S|seq|age_ms|now_ms|FULL/SAME|boot"
    POST /v1/<channel>/status?id=        slave key    body = slave status line (dashboard only)
    GET  /v1/<channel>/state?key=        admin key    JSON view of the channel
    GET  /?key=                          admin key    HTML dashboard
    GET  /health                         none
"""
import argparse
import hashlib
import hmac
import html
import json
import logging
import os
import secrets
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "1.00"
MAX_BODY = 256 * 1024
MAX_LINES = 5000
MAX_WAIT_MS = 10000
BOOT = str(int(time.time() * 1000))  # a restarted server never answers SAME to a slave's old seq

log = logging.getLogger("copier")


# --------------------------------------------------------------------------
# channel state
# --------------------------------------------------------------------------
class Channel:
    def __init__(self, name, master_key, slave_keys):
        self.name = name
        self.master_key = master_key
        self.slave_keys = list(slave_keys)
        self.cond = threading.Condition()
        self.payload = ""
        self.digest = ""
        self.seq = 0
        self.last_push = 0.0
        self.pushes = 0
        self.master_ip = ""
        self.logged_book = None
        self.slaves = {}  # id -> {"ip", "last_pull", "status", "status_ts"}

    def age_ms(self, now=None):
        if not self.last_push:
            return -1
        return int(((now or time.time()) - self.last_push) * 1000)

    def push(self, payload, ip):
        digest = hashlib.sha1(payload.encode("utf-8")).hexdigest()
        with self.cond:
            self.last_push = time.time()
            self.pushes += 1
            self.master_ip = ip
            if digest == self.digest:
                return self.seq, False
            self.digest = digest
            self.payload = payload
            self.seq += 1
            self.cond.notify_all()
            return self.seq, True

    def pull(self, since, wait_ms):
        """Block until seq != since or wait_ms elapses. Returns (seq, age, payload|None)."""
        deadline = time.time() + wait_ms / 1000.0
        with self.cond:
            while self.seq == since:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                self.cond.wait(remaining)
            if self.seq == since:
                return self.seq, self.age_ms(), None
            return self.seq, self.age_ms(), self.payload

    def touch_slave(self, sid, ip):
        s = self.slaves.setdefault(sid, {"ip": ip, "last_pull": 0.0, "status": "", "status_ts": 0.0})
        first = s["last_pull"] == 0.0
        s["ip"] = ip
        s["last_pull"] = time.time()
        return first


def parse_snapshot(payload):
    account, positions = {}, []
    for line in payload.splitlines():
        f = line.strip().split("|")
        if f[0] == "A" and len(f) >= 7:
            account = {"login": f[1], "server": f[2], "currency": f[3],
                       "balance": f[4], "equity": f[5], "leverage": f[6]}
        elif f[0] == "P" and len(f) >= 9:
            positions.append({"ticket": f[1], "symbol": f[2], "type": "BUY" if f[3] == "0" else "SELL",
                              "volume": f[4], "open": f[5], "sl": f[6], "tp": f[7], "magic": f[8]})
    return account, positions


def valid_snapshot(payload):
    lines = [l for l in payload.splitlines() if l.strip()]
    if not lines or len(lines) > MAX_LINES or not lines[0].startswith("A|"):
        return False
    return all(l.startswith(("A|", "P|")) for l in lines)


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------
def load_config(path):
    if not os.path.exists(path):
        cfg = {
            "admin_key": "A-" + secrets.token_urlsafe(18),
            "channels": {
                "main": {
                    "master_key": "M-" + secrets.token_urlsafe(18),
                    "slave_keys": ["S-" + secrets.token_urlsafe(18)],
                }
            },
        }
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
        print(f"Created {path} with new keys - copy them into the EA inputs:")
        print(json.dumps(cfg, indent=2))
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    channels = {}
    for name, c in cfg.get("channels", {}).items():
        if not c.get("master_key") or not c.get("slave_keys"):
            raise SystemExit(f"channel '{name}' needs master_key and at least one slave key")
        channels[name] = Channel(name, c["master_key"], c["slave_keys"])
    if not channels:
        raise SystemExit("config has no channels")
    return cfg.get("admin_key", ""), channels


def key_ok(given, allowed):
    given = (given or "").encode()
    return any(hmac.compare_digest(given, k.encode()) for k in allowed if k)


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MT5Copier/" + VERSION
    channels = {}
    admin_key = ""

    def log_message(self, fmt, *args):  # default access log is far too chatty with long-polling
        log.debug("%s %s", self.client_address[0], fmt % args)

    # -- helpers
    def send_text(self, code, text, ctype="text/plain; charset=utf-8"):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n < 0 or n > MAX_BODY:
            return None
        return self.rfile.read(n).decode("utf-8", errors="replace") if n else ""

    def route(self):
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        q = {k: v[-1] for k, v in parse_qs(u.query).items()}
        return parts, q

    def ip(self):
        return self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()

    def deny(self, what):
        log.warning("auth failed: %s from %s", what, self.ip())
        self.send_text(403, "ERR|forbidden")

    # -- GET
    def do_GET(self):
        parts, q = self.route()
        if parts == ["health"]:
            return self.send_text(200, "OK|" + VERSION)
        if not parts or parts == ["dashboard"]:
            if not key_ok(q.get("key"), [self.admin_key]):
                return self.deny("dashboard")
            return self.send_text(200, self.dashboard(q.get("key")), "text/html; charset=utf-8")
        if len(parts) == 3 and parts[0] == "v1":
            ch = self.channels.get(parts[1])
            if ch is None:
                return self.send_text(404, "ERR|unknown channel")
            if parts[2] == "pull":
                return self.pull(ch, q)
            if parts[2] == "state":
                if not key_ok(q.get("key") or self.headers.get("X-Key"), [self.admin_key]):
                    return self.deny("state")
                return self.send_text(200, json.dumps(self.state(ch), indent=1), "application/json")
        self.send_text(404, "ERR|not found")

    def pull(self, ch, q):
        if not key_ok(self.headers.get("X-Key"), ch.slave_keys):
            return self.deny(f"pull {ch.name}")
        sid = (q.get("id") or self.ip())[:40]
        if ch.touch_slave(sid, self.ip()):
            log.info("[%s] slave '%s' connected from %s", ch.name, sid, self.ip())
        try:
            since = int(q.get("seq", "-1")) if q.get("boot") == BOOT else -1
            wait = max(0, min(int(q.get("wait", "0")), MAX_WAIT_MS))
        except ValueError:
            return self.send_text(400, "ERR|bad query")
        seq, age, payload = ch.pull(since, wait)
        now_ms = int(time.time() * 1000)
        if payload is None:
            return self.send_text(200, f"S|{seq}|{age}|{now_ms}|SAME|{BOOT}\n")
        self.send_text(200, f"S|{seq}|{age}|{now_ms}|FULL|{BOOT}\n{payload}")

    # -- POST
    def do_POST(self):
        parts, q = self.route()
        if len(parts) != 3 or parts[0] != "v1":
            return self.send_text(404, "ERR|not found")
        ch = self.channels.get(parts[1])
        if ch is None:
            return self.send_text(404, "ERR|unknown channel")
        body = self.read_body()
        if body is None:
            return self.send_text(413, "ERR|body too large")

        if parts[2] == "push":
            if not key_ok(self.headers.get("X-Key"), [ch.master_key]):
                return self.deny(f"push {ch.name}")
            body = body.replace("\r", "").strip("\x00").strip()
            if not valid_snapshot(body):
                return self.send_text(400, "ERR|bad snapshot")
            seq, changed = ch.push(body, self.ip())
            book = "\n".join(l for l in body.splitlines() if l.startswith("P|"))
            if changed and book != ch.logged_book:  # heartbeats only refresh equity/time - don't log them
                ch.logged_book = book
                acc, pos = parse_snapshot(body)
                log.info("[%s] seq %d: %d position(s) from master %s (%s)", ch.name, seq, len(pos),
                         acc.get("login", "?"), ", ".join(f"{p['ticket']} {p['type']} {p['volume']} {p['symbol']}"
                                                         for p in pos[:6]) or "flat")
            return self.send_text(200, f"OK|{seq}")

        if parts[2] == "status":
            if not key_ok(self.headers.get("X-Key"), ch.slave_keys):
                return self.deny(f"status {ch.name}")
            sid = (q.get("id") or self.ip())[:40]
            ch.touch_slave(sid, self.ip())
            s = ch.slaves[sid]
            line = body.strip().splitlines()[0][:400] if body.strip() else ""
            def brief(x):  # copies, state, last error - floating P/L changes every tick
                f = x.split("|")
                return [f[i] if i < len(f) else "" for i in (5, 7, 8)]
            if brief(line) != brief(s["status"]):
                log.info("[%s] slave '%s' status: %s", ch.name, sid, line)
            s["status"], s["status_ts"] = line, time.time()
            return self.send_text(200, "OK")

        self.send_text(404, "ERR|not found")

    # -- views
    def state(self, ch):
        now = time.time()
        acc, pos = parse_snapshot(ch.payload)
        slaves = {}
        for sid, s in ch.slaves.items():
            f = s["status"].split("|")
            names = ["login", "server", "currency", "balance", "equity", "copies", "floating", "state", "last_error"]
            slaves[sid] = {"ip": s["ip"], "last_pull_age_s": round(now - s["last_pull"], 1),
                           "status_age_s": round(now - s["status_ts"], 1) if s["status_ts"] else None,
                           **dict(zip(names, f))}
        return {"channel": ch.name, "seq": ch.seq, "pushes": ch.pushes, "master_age_ms": ch.age_ms(now),
                "master_ip": ch.master_ip, "master": acc, "positions": pos, "slaves": slaves}

    def dashboard(self, key):
        e = html.escape
        rows = []
        for ch in self.channels.values():
            st = self.state(ch)
            age = st["master_age_ms"]
            live = 0 <= age < 10000
            rows.append(f"<h2>Channel <code>{e(ch.name)}</code> "
                        f"<span class='{'ok' if live else 'bad'}'>{'LIVE' if live else 'MASTER OFFLINE'}</span></h2>")
            m = st["master"]
            rows.append(f"<p>Master {e(m.get('login', '-'))} @ {e(m.get('server', '-'))} &middot; balance "
                        f"{e(m.get('balance', '-'))} {e(m.get('currency', ''))} &middot; equity {e(m.get('equity', '-'))}"
                        f" &middot; seq {st['seq']} &middot; last push {age / 1000:.1f}s ago</p>" if age >= 0 else
                        "<p>No push received yet.</p>")
            rows.append("<table><tr><th>Ticket</th><th>Symbol</th><th>Side</th><th>Lots</th><th>Open</th>"
                        "<th>SL</th><th>TP</th><th>Magic</th></tr>")
            for p in st["positions"]:
                rows.append("<tr>" + "".join(f"<td>{e(str(p[k]))}</td>" for k in
                                             ("ticket", "symbol", "type", "volume", "open", "sl", "tp", "magic")) + "</tr>")
            if not st["positions"]:
                rows.append("<tr><td colspan=8>flat</td></tr>")
            rows.append("</table><h3>Slaves</h3><table><tr><th>Id</th><th>Login</th><th>Balance</th><th>Equity</th>"
                        "<th>Copies</th><th>Floating</th><th>State</th><th>Last error</th><th>Last poll</th></tr>")
            for sid, s in st["slaves"].items():
                stale = s["last_pull_age_s"] > 15
                rows.append(f"<tr class='{'bad' if stale else ''}'><td>{e(sid)}</td>" + "".join(
                    f"<td>{e(str(s.get(k, '')))}</td>" for k in
                    ("login", "balance", "equity", "copies", "floating", "state", "last_error")) +
                            f"<td>{s['last_pull_age_s']}s</td></tr>")
            if not st["slaves"]:
                rows.append("<tr><td colspan=9>no slave has connected</td></tr>")
            rows.append("</table>")
        return f"""<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="2">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>MT5 Copier</title><style>
body{{font:14px system-ui,sans-serif;margin:16px;background:#fff;color:#111}}
table{{border-collapse:collapse;margin:6px 0 18px}}td,th{{border:1px solid #ccc;padding:3px 8px;text-align:left}}
.ok{{color:#0a7a2f}}.bad{{color:#b3261e}}tr.bad td{{color:#b3261e}}
@media (prefers-color-scheme:dark){{body{{background:#121212;color:#ddd}}td,th{{border-color:#444}}}}
</style></head><body><h1>MT5 Copier relay v{VERSION}</h1>{''.join(rows)}</body></html>"""


def main():
    ap = argparse.ArgumentParser(description="MT5 Copier relay server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--config", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "copy_server.json"))
    ap.add_argument("--cert", help="TLS certificate chain (PEM) - enables HTTPS")
    ap.add_argument("--key", help="TLS private key (PEM)")
    ap.add_argument("--log", help="log file (default: next to the config)")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    logfile = a.log or os.path.splitext(a.config)[0] + ".log"
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s.%(msecs)03d %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S",
                        handlers=[logging.StreamHandler(), logging.FileHandler(logfile, encoding="utf-8")])

    Handler.admin_key, Handler.channels = load_config(a.config)
    httpd = ThreadingHTTPServer((a.host, a.port), Handler)
    httpd.daemon_threads = True
    scheme = "http"
    if a.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(a.cert, a.key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    log.info("MT5 Copier relay v%s on %s://%s:%d  channels: %s", VERSION, scheme, a.host, a.port,
             ", ".join(Handler.channels))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        log.info("stopped")


if __name__ == "__main__":
    main()
