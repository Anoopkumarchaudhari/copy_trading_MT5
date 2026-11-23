"""Scripted master book for testing CopySlave without a live market.

Pushes snapshots to the relay exactly like CopyMaster would (A| and P| lines),
one heartbeat per second, and walks through a fixed scenario. Used by
run_tester_test.py; prints every step with a timestamp.
"""
import time
import urllib.request

M_LOGIN = 1  # not the slave's account, so the same-account guard stays out of the way


class FakeMaster:
    def __init__(self, base, key, log):
        self.base, self.key, self.log = base.rstrip("/"), key, log
        self.book = {}  # ticket -> dict
        self.online = True

    def pos(self, ticket, symbol, side, volume, open_, sl, tp, age_s=0):
        self.book[ticket] = dict(symbol=symbol, type=0 if side == "BUY" else 1, volume=volume, open=open_,
                                 sl=sl, tp=tp, magic=777, time=int(time.time()) - age_s)

    def payload(self):
        lines = [f"A|{M_LOGIN}|FakeBroker|USD|100000|100000|100|{int(time.time())}|fake"]
        for t, p in sorted(self.book.items()):
            lines.append(f"P|{t}|{p['symbol']}|{p['type']}|{p['volume']:g}|{p['open']:.5f}|{p['sl']:.5f}|"
                         f"{p['tp']:.5f}|{p['magic']}|{p['time']}|100000|5")
        return "\n".join(lines)

    def push(self):
        if not self.online:
            return
        req = urllib.request.Request(self.base + "/v1/main/push", data=self.payload().encode(), method="POST",
                                     headers={"X-Key": self.key})
        with urllib.request.urlopen(req, timeout=5) as r:
            r.read()

    def run(self, steps, tail=10):
        """steps: list of (seconds_from_start, description, callable)."""
        t0 = time.time()
        steps = sorted(steps, key=lambda s: s[0])
        i = 0
        end = steps[-1][0] + tail
        while time.time() - t0 < end:
            now = time.time() - t0
            while i < len(steps) and steps[i][0] <= now:
                steps[i][2]()
                self.log(f"MASTER t={now:5.1f}s {steps[i][1]}")
                i += 1
                self.push()
            self.push()
            time.sleep(1.0)


def scenario(fm, buy_open=1.13500, sell_open=1.11000):
    """Wide SL/TP keep the stops valid at any EURUSD price. buy_open sits above and sell_open below
    the tester's market (~1.122 on 2026-10-16) so the one-sided deviation guard lets them through;
    #9000005 is entered far below market on purpose and must be refused."""
    def s_open1(): fm.pos(9000001, "EURUSD", "BUY", 0.10, buy_open, 0.50000, 2.00000)
    def s_open2(): fm.pos(9000002, "EURUSD", "SELL", 0.20, sell_open, 2.00000, 0.50000)
    def s_dev(): fm.pos(9000005, "EURUSD", "BUY", 0.10, 1.05000, 0.0, 0.0)
    def s_mod1(): fm.book[9000001].update(sl=0.60000, tp=1.90000)
    def s_part1(): fm.book[9000001].update(volume=0.06)
    def s_tp2(): fm.book[9000002].update(tp=0.0)
    def s_close1(): fm.book.pop(9000001)
    def s_old(): fm.pos(9000003, "EURUSD", "BUY", 0.10, 1.10000, 0.0, 0.0, age_s=300)
    def s_off(): setattr(fm, "online", False)
    def s_on(): (setattr(fm, "online", True), fm.pos(9000004, "EURUSD", "SELL", 0.10, sell_open, 0.0, 0.0))
    def s_grow(): fm.book[9000004].update(volume=0.30)
    def s_shrink(): fm.book[9000004].update(volume=0.12)
    def s_flat(): fm.book.clear()
    return [
        (4, "OPEN #9000005 BUY 0.10 @1.05, far below market (deviation guard must refuse)", s_dev),
        (8, "OPEN #9000001 BUY 0.10 SL 0.5 TP 2.0", s_open1),
        (16, "OPEN #9000002 SELL 0.20 SL 2.0 TP 0.5", s_open2),
        (24, "MODIFY #9000001 SL 0.6 TP 1.9", s_mod1),
        (32, "PARTIAL #9000001 -> 0.06", s_part1),
        (40, "MODIFY #9000002 TP removed", s_tp2),
        (48, "CLOSE #9000001", s_close1),
        (56, "OPEN #9000003 BUY 0.10 opened 300 s ago (must be skipped)", s_old),
        (64, "GO OFFLINE (no pushes for 20 s, slave must freeze)", s_off),
        (84, "BACK ONLINE + OPEN #9000004 SELL 0.10", s_on),
        (94, "GROW #9000004 -> 0.30 (netting add)", s_grow),
        (104, "SHRINK #9000004 -> 0.12", s_shrink),
        (114, "FLAT - everything closed", s_flat),
    ]
