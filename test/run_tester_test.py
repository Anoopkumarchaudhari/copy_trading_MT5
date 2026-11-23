"""Weekend test of JB_CopySlave: Strategy Tester + real relay + scripted master.

    python run_tester_test.py [normal|reverse]

The slave runs in the tester of mt5clone_c (EURUSD M1 OHLC, 2026-10-16) with the WinINet
transport and long-polls the real relay server; fake_master.py pushes the scenario book.
InpPollMs = 5 simulated minutes, and each long-poll blocks the tester for up to 1 s of real
time, so one tester day (288 polls) takes ~5 real minutes and the scenario (8 s per step) is
seen step by step. The tester then finishes on its own, which is when the agent writes the
EA's log. Output: test/results/tester_<pass>_*.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

from fake_master import FakeMaster, scenario

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES = os.path.join(HERE, "results")
CLONE = r"D:\Strategy\mt5clone_c"
PORT = 8787
LOGLINES = []


def log(msg):
    line = f"{datetime.now():%H:%M:%S.%f}"[:-3] + " " + msg
    LOGLINES.append(line)
    print(line, flush=True)


def write_ascii(path, lines):
    with open(path, "w", encoding="ascii", newline="\r\n") as fh:
        fh.write("\n".join(lines) + "\n")


def kill_clone():
    ps = (f"Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | "
          f"Where-Object {{ $_.Path -like '{CLONE}\\*' }} | Stop-Process -Force")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], check=False)


PASSES = {
    "normal": [],
    "reverse": ["InpReverse=true", "InpSLTPMode=1", "InpMaxDeviationPts=0"],
}


def running():
    ps = (f"@(Get-Process terminal64,metatester64 -ErrorAction SilentlyContinue | "
          f"Where-Object {{ $_.Path -like '{CLONE}\\*' }}).Count")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip()
    return out not in ("", "0")


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "normal"
    os.makedirs(RES, exist_ok=True)
    cfg_path = os.path.join(HERE, "copy_server_test.json")
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    srv_log = os.path.join(RES, f"tester_{name}_server.log")
    if os.path.exists(srv_log):
        os.remove(srv_log)
    srv = subprocess.Popen([sys.executable, os.path.join(ROOT, "server", "copy_server.py"), "--host", "127.0.0.1",
                            "--port", str(PORT), "--config", cfg_path, "--log", srv_log],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)

    dst = os.path.join(CLONE, "MQL5", "Experts", "JB_Copier")
    os.makedirs(dst, exist_ok=True)
    shutil.copy2(os.path.join(ROOT, "mql5", "JB_CopySlave.ex5"), dst)
    prof = os.path.join(CLONE, "MQL5", "Profiles", "Tester")
    os.makedirs(prof, exist_ok=True)
    write_ascii(os.path.join(prof, "jbc_slave_tester.set"), [
        f"InpServerUrl=http://127.0.0.1:{PORT}", "InpChannel=main",
        f"InpSlaveKey={cfg['channels']['main']['slave_keys'][0]}", "InpSlaveId=tester", "InpTransport=1",
        "InpLotMode=1", "InpLotValue=0.5", "InpMagic=26101701", "InpWaitMs=1000", "InpPollMs=300000"] + PASSES[name])
    ini = os.path.join(CLONE, "jbc_tester.ini")
    write_ascii(ini, [
        "[Experts]", "AllowDllImport=1", "Enabled=1",
        "[Tester]", "Expert=JB_Copier\\JB_CopySlave", "ExpertParameters=jbc_slave_tester.set",
        "Symbol=EURUSD", "Period=M1", "Model=1", "FromDate=2026.10.16", "ToDate=2026.10.17",
        "Deposit=100000", "Currency=USD", "Leverage=100", "Optimization=0", "Visual=0",
        "Report=jbc_tester_report", "ReplaceReport=1", "ShutdownTerminal=1"])

    t_start = time.time()
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 7  # SW_SHOWMINNOACTIVE
    subprocess.Popen([os.path.join(CLONE, "terminal64.exe"), "/portable", f"/config:{ini}"], cwd=CLONE, startupinfo=si)
    log("tester launched")
    try:
        deadline = time.time() + 240
        while time.time() < deadline:
            if os.path.exists(srv_log) and "slave 'tester' connected" in open(srv_log, encoding="utf-8").read():
                break
            time.sleep(0.5)
        else:
            raise TimeoutError("slave never connected")
        log("slave connected - running scenario")
        fm = FakeMaster(f"http://127.0.0.1:{PORT}", cfg["channels"]["main"]["master_key"], log)
        fm.run(scenario(fm), tail=12)
        log("scenario done - waiting for the tester to finish its day")
        deadline = time.time() + 900
        while time.time() < deadline and running():
            time.sleep(2)
        log("tester finished" if not running() else "tester still running after 15 min - killing it")
    finally:
        kill_clone()
        time.sleep(1)
        srv.terminate()

    # newest agent log written during this run
    logs = [p for p in glob.glob(os.path.join(CLONE, "Tester", "Agent-*", "logs", "*.log")) if os.path.getmtime(p) >= t_start]
    out = []
    for p in logs:
        text = open(p, "rb").read().decode("utf-16", errors="replace")
        out += [l.split("\t", 2)[-1] for l in text.splitlines()
                if any(k in l for k in ("JBCS", "deal #", "failed", "error"))]
    with open(os.path.join(RES, f"tester_{name}_slave.log"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))
    with open(os.path.join(RES, f"tester_{name}_master_steps.log"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(LOGLINES))
    log(f"agent logs: {logs}")


if __name__ == "__main__":
    main()
