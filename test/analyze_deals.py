"""Pair master (driver) deals with slave copy deals from results/jbc_deals.csv and report copy latency.

    python analyze_deals.py [path/to/jbc_deals.csv]
"""
import csv
import os
import sys

DRIVER, SLAVE = "26101799", "26101701"
ENTRY = {"0": "IN", "1": "OUT", "2": "INOUT", "3": "OUT_BY"}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "jbc_deals.csv")
    rows = list(csv.DictReader(open(path, encoding="ascii", errors="replace")))
    master = [r for r in rows if r["magic"] == DRIVER]
    slave = [r for r in rows if r["magic"] == SLAVE]
    # slave position -> master position, from the CP#<ticket> comment on the opening deal
    link = {r["position"]: r["comment"][3:] for r in slave if r["entry"] == "0" and r["comment"].startswith("CP#")}
    used = set()
    lat = []
    print(f"{'master deal':<34}{'slave deal':<34}{'latency':>9}")
    for m in master:
        best = None
        for s in slave:
            if s["deal"] in used or link.get(s["position"]) != m["position"] or s["entry"] != m["entry"]:
                continue
            dt = int(s["time_msc"]) - int(m["time_msc"])
            if dt >= -500 and (best is None or dt < best[0]):
                best = (dt, s)
        side = "BUY" if m["type"] == "0" else "SELL"
        mtxt = f"#{m['position']} {ENTRY[m['entry']]:<3} {side:<4} {float(m['volume']):.2f} {m['symbol']}"
        if best:
            used.add(best[1]["deal"])
            s = best[1]
            stxt = f"#{s['position']} {ENTRY[s['entry']]:<3} {'BUY' if s['type'] == '0' else 'SELL':<4} {float(s['volume']):.2f}"
            print(f"{mtxt:<34}{stxt:<34}{best[0]:>7} ms")
            lat.append(best[0])
        else:
            print(f"{mtxt:<34}{'-- no copy --':<34}")
    extra = [s for s in slave if s["deal"] not in used]
    for s in extra:
        print(f"{'':<34}#{s['position']} {ENTRY[s['entry']]} {float(s['volume']):.2f} unmatched slave deal ({s['comment']})")
    if lat:
        lat.sort()
        print(f"\n{len(lat)} copied actions, latency median {lat[len(lat) // 2]} ms, max {lat[-1]} ms")
    print(f"master net {sum(float(r['profit']) for r in master):.2f}, slave net {sum(float(r['profit']) for r in slave):.2f}")


if __name__ == "__main__":
    main()
