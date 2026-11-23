"""JB Copier live demo test.

    python run_live_test.py

Starts the relay server and three headless clone terminals on the demo account:
    mt5clone_c  JB_CopySlave       (copies with magic 26101701, lots x0.5, WinINet transport)
    mt5clone_b  JB_CopyMaster      (publishes only the driver's magic 26101799)
    mt5clone    JB_CopyTestDriver  (plays the scenario, exports deals at the end)
Phase 2 kills the master terminal for ~25 s (slave must freeze, then catch up);
phase 3 hard-kills and restarts the slave (it must re-link, not duplicate).
Everything lands in test/results/.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES = os.path.join(HERE, "results")
COMMON = os.path.expandvars(r"%APPDATA%\MetaQuotes\Terminal\Common\Files")
CLONES = {"slave": r"D:\Strategy\mt5clone_c", "master": r"D:\Strategy\mt5clone_b", "driver": r"D:\Strategy\mt5clone"}
EXPERTS = {"slave": "JB_CopySlave", "master": "JB_CopyMaster", "driver": "JB_CopyTestDriver"}
PORT = 8787


def log(msg):
    print(f"{datetime.now():%H:%M:%S} {msg}", flush=True)


def write_ascii(path, lines):
    with open(path, "w", encoding="ascii", newline="\r\n") as fh:
        fh.write("\n".join(lines) + "\n")


def prepare(cfg):
    master_key = cfg["channels"]["main"]["master_key"]
    slave_key = cfg["channels"]["main"]["slave_keys"][0]
    sets = {
        "master": [f"InpServerUrl=http://127.0.0.1:{PORT}", "InpChannel=main", f"InpMasterKey={master_key}",
                   "InpTransport=1", "InpMagicInclude=26101799"],
        "slave": [f"InpServerUrl=http://127.0.0.1:{PORT}", "InpChannel=main", f"InpSlaveKey={slave_key}",
                  "InpSlaveId=clone_c", "InpTransport=1", "InpLotMode=1", "InpLotValue=0.5", "InpMagic=26101701"],
        "driver": ["InpMagic=26101799", "InpSlaveMagic=26101701", "InpStartDelay=25"],
    }
    for role, clone in CLONES.items():
        dst = os.path.join(clone, "MQL5", "Experts", "JB_Copier")
        os.makedirs(dst, exist_ok=True)
        for f in ("JB_CopyMaster.ex5", "JB_CopySlave.ex5"):
            shutil.copy2(os.path.join(ROOT, "mql5", f), dst)
        shutil.copy2(os.path.join(HERE, "JB_CopyTestDriver.ex5"), dst)
        os.makedirs(os.path.join(clone, "MQL5", "Presets"), exist_ok=True)
        write_ascii(os.path.join(clone, "MQL5", "Presets", f"jbc_{role}_test.set"), sets[role])
        write_ascii(os.path.join(clone, f"jbc_{role}.ini"), [
            "[Experts]", "Enabled=1", "AllowLiveTrading=1", "AllowDllImport=1",
            "[StartUp]", f"Expert=JB_Copier\\{EXPERTS[role]}", f"ExpertParameters=jbc_{role}_test.set",
            "Symbol=EURUSD", "Period=M1"])


def start(role):
    clone = CLONES[role]
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 7  # SW_SHOWMINNOACTIVE - don't steal the desktop
    p = subprocess.Popen([os.path.join(clone, "terminal64.exe"), "/portable", f"/config:{clone}\\jbc_{role}.ini"],
                         cwd=clone, startupinfo=si)
    log(f"started {role} terminal pid {p.pid}")
    return p


def kill(role, procs):
    p = procs.get(role)
    if p and p.poll() is None:
        p.kill()
        p.wait(10)
        log(f"killed {role} terminal pid {p.pid}")


def marks():
    try:
        with open(os.path.join(COMMON, "jbc_driver.txt"), encoding="ascii", errors="replace") as fh:
            return [l.strip() for l in fh if l.strip()]
    except FileNotFoundError:
        return []


def wait_mark(word, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for l in marks():
            if word in l:
                return l
        time.sleep(0.5)
    raise TimeoutError(word)


def main():
    os.makedirs(RES, exist_ok=True)
    for f in ("jbc_driver.txt", "jbc_deals.csv"):
        if os.path.exists(os.path.join(COMMON, f)):
            os.remove(os.path.join(COMMON, f))
    cfg_path = os.path.join(HERE, "copy_server_test.json")
    server_log = os.path.join(RES, "server.log")
    if os.path.exists(server_log):
        os.remove(server_log)
    srv = subprocess.Popen([sys.executable, os.path.join(ROOT, "server", "copy_server.py"), "--host", "127.0.0.1",
                            "--port", str(PORT), "--config", cfg_path, "--log", server_log],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    prepare(cfg)
    t_start = datetime.now()
    procs = {}
    try:
        procs["slave"] = start("slave")
        time.sleep(3)
        procs["master"] = start("master")
        time.sleep(3)
        procs["driver"] = start("driver")
        wait_mark("driver started", 60)
        log("driver running")

        log("phase 2 mark: " + wait_mark("PHASE2", 200))
        time.sleep(5)
        kill("master", procs)
        time.sleep(25)
        procs["master"] = start("master")

        log("phase 3 mark: " + wait_mark("PHASE3", 200))
        time.sleep(8)
        kill("slave", procs)
        time.sleep(5)
        procs["slave"] = start("slave")

        log("done mark: " + wait_mark("DONE", 200))
        time.sleep(3)
    finally:
        for role in ("driver", "master", "slave"):
            kill(role, procs)
        time.sleep(2)
        srv.terminate()

    # collect
    day = t_start.strftime("%Y%m%d")
    for role, clone in CLONES.items():
        src = os.path.join(clone, "MQL5", "Logs", f"{day}.log")
        if os.path.exists(src):
            with open(src, "rb") as fh:
                raw = fh.read()
            text = raw.decode("utf-16", errors="replace")
            since = t_start.strftime("%H:%M:%S")
            keep = []
            for l in text.splitlines():
                f = l.split("\t")
                if len(f) >= 4 and f[2][:8] >= since:
                    keep.append("\t".join(f[2:]))
            with open(os.path.join(RES, f"{role}_experts.log"), "w", encoding="utf-8") as fh:
                fh.write("\n".join(keep))
    for f in ("jbc_driver.txt", "jbc_deals.csv"):
        if os.path.exists(os.path.join(COMMON, f)):
            shutil.copy2(os.path.join(COMMON, f), RES)
    log("results in " + RES)


if __name__ == "__main__":
    main()
