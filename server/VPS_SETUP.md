# Run copy_server.py on a VPS

No pip packages are needed. Python 3.8+ is enough.
Part A = Windows VPS (RDP). Part B = Linux VPS (Ubuntu / Debian).

---

# Part A: Windows VPS

## 1. Install Python
Download from https://www.python.org/downloads/windows/ and tick **"Add python.exe to PATH"**.
Check in PowerShell:
```powershell
python --version
```
(`python3` does not exist on Windows; use `python` or `py`.)

## 2. Put the server file on the VPS
Create a folder and copy ONLY this file into it from your PC
(`server\copy_server.py` from this repository). Over RDP: right-click copy the file on
your PC, right-click paste inside the VPS Explorer window.
```powershell
New-Item -ItemType Directory -Force C:\jb_copier
```
If you want to keep the keys already in your EAs, also copy your local `copy_server.json`
next to it. Otherwise the first run creates a new one with fresh random keys.

Verify the file is the real server (about 370 lines, first lines mention JB Copier):
```powershell
(Get-Content C:\jb_copier\copy_server.py | Measure-Object -Line).Lines
Get-Content C:\jb_copier\copy_server.py -TotalCount 3
```

## 3. First run (generates keys, verifies it starts)
```powershell
cd C:\jb_copier
python copy_server.py --host 0.0.0.0 --port 8787
```
A good start prints one line and then keeps running (does not return to the prompt):
```
2026-11-23 12:00:00.000 INFO JB Copier relay v1.x on http://0.0.0.0:8787  channels: main
```
Press Ctrl+C to stop, then read the keys:
```powershell
Get-Content C:\jb_copier\copy_server.json
```
Put `master_key` into JB_CopyMaster, a `slave_key` into each JB_CopySlave, keep `admin_key`
for the dashboard.

## 4. Open the Windows firewall
```powershell
netsh advfirewall firewall add rule name="JB Copier 8787" dir=in action=allow protocol=TCP localport=8787
```
Also open TCP 8787 in the VPS provider's cloud firewall / security group if it has one.

## 5. Keep it running after you close RDP (Task Scheduler)
Find the python path first:
```powershell
(Get-Command python).Source
```
Create a task that starts at boot as SYSTEM (replace the python path with yours):
```powershell
schtasks /Create /F /TN "JB Copier" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "\"C:\Users\Administrator\AppData\Local\Programs\Python\Python314\python.exe\" C:\jb_copier\copy_server.py --host 0.0.0.0 --port 8787 --config C:\jb_copier\copy_server.json"
schtasks /Run /TN "JB Copier"
schtasks /Query /TN "JB Copier" /V /FO LIST
```
Log file: `C:\jb_copier\copy_server.log`.
```powershell
Get-Content C:\jb_copier\copy_server.log -Tail 20 -Wait
```
Stop / restart (after editing copy_server.json):
```powershell
schtasks /End /TN "JB Copier"
schtasks /Run /TN "JB Copier"
```

## 6. Test from your PC
```powershell
curl.exe "http://<VPS_IP>:8787/v1/main/state?key=<admin_key>"
```
Dashboard in a browser: `http://<VPS_IP>:8787/?key=<admin_key>`

## 7. HTTPS on Windows
MT5 WebRequest rejects self-signed certificates. Either stay on plain HTTP, or get a real
certificate (win-acme: https://www.win-acme.com, needs a domain pointing at the VPS) and add
`--cert fullchain.pem --key privkey.pem` to the command in step 5.

---

# Part B: Linux VPS (Ubuntu / Debian)

## 1. Install Python and create a service user
```bash
sudo apt update && sudo apt install -y python3
sudo useradd --system --create-home --shell /usr/sbin/nologin copier
sudo mkdir -p /opt/jb_copier/server
```

## 2. Upload the server files
From your PC (PowerShell), copy the two files to the VPS:
```powershell
scp server\copy_server.py   root@<VPS_IP>:/opt/jb_copier/server/
scp server\jb-copier.service root@<VPS_IP>:/opt/jb_copier/server/
```
If you want to keep the keys you already generated locally, also copy `copy_server.json`.
Otherwise the first run creates a new one with fresh random keys.

## 3. First run (generates keys, verifies it starts)
```bash
sudo chown -R copier:copier /opt/jb_copier
cd /opt/jb_copier/server
sudo -u copier python3 copy_server.py --host 0.0.0.0 --port 8787
```
Watch for the "listening" line, then press Ctrl+C. Print the keys:
```bash
cat /opt/jb_copier/server/copy_server.json
```
Put `master_key` into JB_CopyMaster, a `slave_key` into each JB_CopySlave,
and keep `admin_key` for the dashboard.

## 4. Install as a systemd service (auto-start, auto-restart)
```bash
sudo cp /opt/jb_copier/server/jb-copier.service /etc/systemd/system/jb-copier.service
sudo systemctl daemon-reload
sudo systemctl enable --now jb-copier
sudo systemctl status jb-copier --no-pager
```
Logs:
```bash
sudo journalctl -u jb-copier -f
tail -f /opt/jb_copier/server/copy_server.log
```

## 5. Open the firewall
```bash
sudo ufw allow 8787/tcp
sudo ufw reload
```
Also open TCP 8787 in the VPS provider's cloud firewall / security group.

## 6. Test from your PC
```powershell
curl.exe "http://<VPS_IP>:8787/v1/main/state?key=<admin_key>"
```
Dashboard in a browser: `http://<VPS_IP>:8787/?key=<admin_key>`

## 7. HTTPS (recommended over the internet)
MT5 WebRequest rejects self-signed certificates, so use a real one:
```bash
sudo apt install -y certbot
sudo certbot certonly --standalone -d copier.yourdomain.com
sudo setfacl -R -m u:copier:rX /etc/letsencrypt/live /etc/letsencrypt/archive
```
Then edit `/etc/systemd/system/jb-copier.service`, add to `ExecStart`:
```
--cert /etc/letsencrypt/live/copier.yourdomain.com/fullchain.pem --key /etc/letsencrypt/live/copier.yourdomain.com/privkey.pem
```
and run `sudo systemctl daemon-reload && sudo systemctl restart jb-copier`.
Use `https://copier.yourdomain.com:8787/...` in the EAs and the WebRequest allow-list.

## Useful commands
```bash
sudo systemctl restart jb-copier     # after editing copy_server.json
sudo systemctl stop jb-copier
sudo systemctl disable jb-copier
```
