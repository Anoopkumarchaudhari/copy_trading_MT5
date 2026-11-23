# JB Copier: remote trade copier for MT5

One **master** MT5 account publishes its open positions to a small relay server.
Any number of **slave** MT5 accounts, on any PC, VPS or broker, pull that book and
mirror it with their own lot sizing.

```
 MT5 master terminal                 relay server (VPS)                 MT5 slave terminals
┌───────────────────┐  POST push   ┌──────────────────────┐  GET pull  ┌───────────────────┐
│ JB_CopyMaster EA  │ ───────────► │ copy_server.py       │ ◄───────── │ JB_CopySlave EA   │
│ snapshot of all   │  on change + │ keeps latest book    │ long-poll  │ reconcile own     │
│ open positions    │  every 2 s   │ per channel, keys,   │ (wakes on  │ positions vs book │
└───────────────────┘              │ dashboard            │  change)   └───────────────────┘
                                   └──────────────────────┘
```

| File | What it is |
|---|---|
| `server/copy_server.py` | Relay server. Python 3.8+ standard library only, no pip install. |
| `mql5/JB_CopyMaster.mq5` | Master EA. Publishes positions and never trades. |
| `mql5/JB_CopySlave.mq5` | Slave EA. Opens, closes and modifies copies. Default magic `26101701`. |
| `mql5/JB_CopierNet.mqh` | HTTP transport shared by both EAs (WebRequest or WinINet). |
| `test/` | Live demo test: driver EA, runner script, results. |

## How it works

The slave reconciles against snapshots. It doesn't replay events. Every time the slave
gets an answer from the server, it compares the master's book with its own copies:

| Master book says | Slave does |
|---|---|
| New position | Opens one copy, once per master ticket, after the age, price-deviation and lot checks |
| Position gone | Closes its copies |
| Volume reduced (partial close) | Closes the same proportion of the copy |
| Volume increased (netting master) | Opens an add-on copy |
| SL/TP changed | Modifies the copy |
| Master silent for more than `InpStaleSec` | **Freezes.** It opens nothing and closes nothing until the master is back |

Because it compares whole snapshots, a slave that restarts, loses its connection or
misses an update fixes itself on the next answer. It never "replays" a missed close.

Safety rules built in:
- The master **never pushes while disconnected** from its broker, nor during the first
  3 s after it reconnects. While a terminal is synchronising its book looks empty, and
  pushing that empty book would make every slave close everything.
- Removing the master EA sends nothing, so the slaves freeze instead of closing.
- A copy that closes on the slave side (its own SL hit, or a manual close) is **not reopened**.
- Copies carry magic `InpMagic` and the comment `CP#<master ticket>`. Their state lives in
  terminal global variables `JBCS.<magic>.*`, flushed after every change, so a hard-killed
  terminal comes back and re-links its copies.
- A master trade older than `InpMaxSignalAgeSec` is not copied, and neither is one whose
  price has already moved more than `InpMaxDeviationPts` against the slave.
- If master and slave are the same account, the slave ignores positions with its own magic,
  which prevents copy-of-copy loops.

## Setup

### 1. Server (VPS or any always-on PC)

```
python copy_server.py --host 0.0.0.0 --port 8787
```

The first run writes `copy_server.json` with fresh random keys:
- one `master_key` per channel
- one or more `slave_keys`
- one `admin_key` for the dashboard

Add more channels or slave keys by editing that file and restarting the server.
Open TCP port 8787 in the VPS firewall.

- Dashboard: `http://<server>:8787/?key=<admin_key>`. It refreshes every 2 s and shows the
  master book, every slave's balance, equity, copies and state, and the last error.
- JSON state for scripts: `GET /v1/main/state?key=<admin_key>`.
- Log file: `copy_server.log`, next to the config.
- Over the internet, use HTTPS: `--cert fullchain.pem --key privkey.pem` with a real
  certificate (for example from Let's Encrypt), or put Caddy or nginx in front.
  WebRequest rejects self-signed certificates.
- To keep it running: on Windows use Task Scheduler ("At startup", "Run whether user is
  logged on or not"); on Linux use a systemd unit.

### 2. Allow the URL in every terminal (WebRequest transport)

In MT5, open Tools → Options → Expert Advisors, tick "Allow WebRequest for listed URL"
and add `http://<server>:8787`. Use the exact scheme, host and port the EA uses.

MT5 encrypts this list in `config\common.ini`. A startup `/config` file **cannot** set it;
it only wipes the list. On a terminal where nobody can open that dialog, such as a headless
VPS clone, use `InpTransport = WinINet` instead. That transport needs "Allow DLL imports"
but no URL list. It also keeps the connection open between requests.

### 3. Master EA

Attach `JB_CopyMaster` to any one chart on the master account and set:
- `InpServerUrl` and `InpChannel`
- `InpMasterKey`
- `InpMagicInclude` (optional): publish only these EA magics, `0` = manual trades. Empty = everything.
- `InpMagicExclude`: magics never to publish. If a slave runs on the same account, put its magic here.
- `InpSymbols` (optional): publish only these symbols.

The chart comment shows LIVE or the error, the number of positions published, the
sequence number and the age of the last push.

### 4. Slave EA

Attach `JB_CopySlave` to any one chart on each follower account. It must be a hedging account.

| Input | Meaning |
|---|---|
| `InpSlaveKey`, `InpSlaveId` | Key from the config; name shown on the dashboard |
| `InpLotMode` | `Fixed`, `Multiplier`, `BalanceRatio` (default) or `EquityRatio`; `InpLotValue` is the lot or the multiplier |
| `InpMaxLot`, `InpRoundUpToMin` | Cap per copy; what to do below the broker minimum |
| `InpAdjustContract` | Scales lots when contract sizes differ (gold 100 oz vs 1 oz) |
| `InpSymbolMap`, `InpMasterSuffix`, `InpSlaveSuffix` | `GOLD=XAUUSD`, strip `.fx`, add `.m` |
| `InpSymbolsAllow`, `InpMagicAllow` | Copy only some symbols or master strategies |
| `InpCopyExisting` | Also copy positions already open when the slave starts. Off by default. |
| `InpMaxSignalAgeSec` | Don't open copies of master trades older than this. Default 60 s. |
| `InpMaxDeviationPts` | Skip the entry if the price moved this many points **against** the slave. Default 50; raise it for gold or indices. |
| `InpCopySLTP`, `InpSLTPMode` | Copy SL/TP as the same prices, or as the same distance from entry (use distance for another broker's quotes) |
| `InpReverse` | Copy BUY as SELL and SELL as BUY. SL and TP swap roles. |
| `InpMaxCopies`, `InpDailyLossLimit` | Stop opening new copies at N open copies, or after this day loss. Closing and modifying continue. |
| `InpStaleSec` | Master silent this long counts as offline: the slave freezes. Default 10 s. |

## Tests

### Strategy Tester + real relay (2026-10-17, weekend): PASSED

`test/run_tester_test.py normal|reverse` runs `JB_CopySlave` in the Strategy Tester of
`D:\Strategy\mt5clone_c` against the real relay. `test/fake_master.py` pushes a scripted master
book, and the tester fills the slave's orders on EURUSD prices from 2026-10-16. Logs are in
`test/results/tester_*`.

**Normal pass** (lots ×0.5):

| Master | Slave |
|---|---|
| BUY 0.10 | OPEN BUY 0.05 |
| SELL 0.20 | OPEN SELL 0.10 |
| SL/TP modified | MODIFY, same prices |
| Partial close 0.10 → 0.06 | REDUCE 0.05 → 0.03 |
| TP removed | TP removed |
| Closed | Copy closed |
| Trade opened 300 s ago | Skipped (age) |
| Entry 7,180 points worse than market | Refused, then skipped at 61 s |
| Silent for 20 s | No actions at all (frozen) |
| New trade after the outage | Copied |
| Netting grow 0.10 → 0.30 | ADD 0.10 |
| Shrink to 0.12 | Newest copy reduced by 0.09 |
| Flat | All 3 copies closed |

**Reverse pass** (distance-mode SL/TP):

| Master | Slave |
|---|---|
| BUY | SELL |
| SL 0.6 / TP 1.9 around entry 1.135 | SL 1.88685 / TP 0.58685 around entry 1.12185 |
| TP removed | SL removed (SL and TP swap roles in reverse) |
| Partial, add-on, reduce, flat | Same as the normal pass |

### Live demo test: needs an open market

`python test/run_live_test.py`, then `python test/analyze_deals.py`.

The script starts the relay and three clone terminals on demo account 10012289342:

| Clone | Runs | Settings |
|---|---|---|
| `mt5clone_c` | slave | magic 26101701, lots ×0.5 |
| `mt5clone_b` | master | publishes only magic 26101799 |
| `mt5clone` | `JB_CopyTestDriver` | trades EURUSD and GBPUSD, 0.10 lots |

The scenario runs open, SL/TP modify, partial close and close, then two failure tests:
- The master terminal is killed for 25 s while the driver opens a new trade.
- The slave is hard-killed and restarted mid-trade.

`analyze_deals.py` pairs every master deal with its copy and prints the copy latency.
The first attempt on 2026-10-17 was rejected by the broker with "market closed", so run it
after 02:30 IST on Monday.

## Limits

- **The slave needs a hedging account.** A netting slave can't keep two master tickets
  apart on one symbol. A netting master is fine.
- **Pending orders are not copied.** When a master pending order fills, it becomes a position
  and is copied at market.
- **Latency** is roughly: one push, plus one long-poll wake-up (the relay itself answers in
  milliseconds), plus the slave's own order round trip to its broker. On the MetaQuotes demo
  that round trip is about 150 ms. The live test measures the total.
- **Copying for other people is regulated.** Copying your own signals into other people's
  accounts for money is regulated (SEBI in India). Copying between your own accounts is not.
