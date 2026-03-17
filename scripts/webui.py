#!/usr/bin/env python3
"""
DNS-345 NAS Web Dashboard — lightweight status page
No dependencies beyond Python 3 standard library.
Run: python3 webui.py [--port 8080]
"""

import http.server
import subprocess
import os
import time
import json
import argparse
import html

PORT = 8080


def run(cmd):
    """Run a shell command and return stdout."""
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except Exception:
        return ""


def get_uptime():
    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
        days, r = divmod(secs, 86400)
        hours, r = divmod(r, 3600)
        mins, _ = divmod(r, 60)
        if days > 0:
            return f"{days}j {hours}h {mins}m"
        return f"{hours}h {mins}m"
    except Exception:
        return "?"


def get_load():
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
            return parts[0], parts[1], parts[2]
    except Exception:
        return "?", "?", "?"


def get_memory():
    try:
        with open("/proc/meminfo") as f:
            info = {}
            for line in f:
                k, v = line.split(":")
                info[k.strip()] = int(v.strip().split()[0])
        total = info["MemTotal"] // 1024
        avail = info.get("MemAvailable", info.get("MemFree", 0)) // 1024
        used = total - avail
        pct = int(used * 100 / total) if total else 0
        return total, used, pct
    except Exception:
        return 0, 0, 0


def get_temperature():
    """Read LM75 temperature sensor via I2C sysfs."""
    for hwmon in ["/sys/class/hwmon/hwmon0", "/sys/class/hwmon/hwmon1", "/sys/class/hwmon/hwmon2"]:
        path = f"{hwmon}/temp1_input"
        if os.path.exists(path):
            try:
                with open(path) as f:
                    return int(f.read().strip()) / 1000
            except Exception:
                pass
    # Fallback: direct I2C read
    raw = run("i2cget -y 0 0x48 0x00 w 2>/dev/null")
    if raw:
        try:
            val = int(raw, 16)
            temp = ((val & 0xFF) << 1) | ((val >> 15) & 1)
            return temp * 0.5
        except Exception:
            pass
    return None


def get_raid_status():
    mdstat = run("cat /proc/mdstat")
    if not mdstat:
        return None, None, None
    status = "OK"
    detail = ""
    progress = ""
    for line in mdstat.split("\n"):
        if "md0" in line:
            detail = line.strip()
        if "[" in line and "_" in line:
            status = "DEGRADED"
        if "[UUUU]" in line or "[UU]" in line:
            status = "OK"
        if "recovery" in line or "reshape" in line or "resync" in line:
            status = "SYNCING"
            progress = line.strip()
    return status, detail, progress


def get_disks():
    lines = run("df -h /srv/data / 2>/dev/null").split("\n")
    disks = []
    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 6:
            disks.append({
                "dev": parts[0],
                "size": parts[1],
                "used": parts[2],
                "avail": parts[3],
                "pct": parts[4],
                "mount": parts[5],
            })
    return disks


def get_smart():
    """Get SMART health for each SATA disk."""
    results = []
    for dev in ["sda", "sdb", "sdc", "sde"]:
        path = f"/dev/{dev}"
        if not os.path.exists(path):
            continue
        health = run(f"smartctl -H {path} 2>/dev/null | grep 'result'")
        smart_all = run(f"smartctl -AH {path} 2>/dev/null")

        passed = "PASSED" in smart_all if smart_all else None
        disk_temp = ""
        power_hours = ""
        realloc_count = ""
        for line in smart_all.split("\n"):
            low = line.lower()
            if "temperature_celsius" in low or "airflow_temperature" in low:
                # Format: "194 Temperature_Celsius ... 26 (0 8 0 0 0)"
                # The raw value starts after the last "-"
                raw = line.split("-")[-1].strip().split()[0] if "-" in line else ""
                if raw and not disk_temp:
                    disk_temp = raw
            elif "power_on_hours" in low:
                raw = line.split("-")[-1].strip().split()[0] if "-" in line else ""
                power_hours = raw
            elif "reallocated_sector" in low:
                raw = line.split("-")[-1].strip().split()[0] if "-" in line else ""
                realloc_count = raw

        results.append({
            "dev": dev,
            "health": "OK" if passed else ("FAIL" if passed is False else "?"),
            "temp": disk_temp,
            "hours": power_hours,
            "realloc": realloc_count,
        })
    return results


def get_services():
    services = []
    for name, check in [("SSH", "sshd"), ("Samba", "smbd"), ("NTP", "ntpd"), ("SMART", "smartd"), ("Dashboard", "nas-dashboard")]:
        pid = run(f"pidof {check}")
        services.append({"name": name, "running": bool(pid)})
    return services


def get_network():
    ip = run("hostname -I 2>/dev/null").split()
    hostname = run("hostname")
    return hostname, ip


def get_last_backup():
    """Read last backup status."""
    log = run("tail -1 /var/log/backup-rootfs.log 2>/dev/null")
    return log if log else "No backup yet"


def pct_to_int(pct_str):
    try:
        return int(pct_str.replace("%", ""))
    except Exception:
        return 0


def render_page():
    hostname, ips = get_network()
    uptime = get_uptime()
    load1, load5, load15 = get_load()
    mem_total, mem_used, mem_pct = get_memory()
    temp = get_temperature()
    raid_status, raid_detail, raid_progress = get_raid_status()
    disks = get_disks()
    smart = get_smart()
    services = get_services()
    last_backup = get_last_backup()
    now = time.strftime("%Y-%m-%d %H:%M:%S")

    # RAID color
    raid_color = {"OK": "#4caf50", "DEGRADED": "#f44336", "SYNCING": "#ff9800"}.get(raid_status, "#999")

    # Temp color
    if temp is not None:
        if temp < 40:
            temp_color = "#4caf50"
        elif temp < 50:
            temp_color = "#ff9800"
        else:
            temp_color = "#f44336"
        temp_str = f"{temp:.1f}"
    else:
        temp_color = "#999"
        temp_str = "?"

    # Memory bar color
    mem_color = "#4caf50" if mem_pct < 70 else "#ff9800" if mem_pct < 90 else "#f44336"

    # Disk rows
    disk_rows = ""
    for d in disks:
        pct = pct_to_int(d["pct"])
        bar_color = "#4caf50" if pct < 80 else "#ff9800" if pct < 95 else "#f44336"
        disk_rows += f"""
        <tr>
            <td><code>{html.escape(d['dev'])}</code></td>
            <td>{html.escape(d['mount'])}</td>
            <td>{html.escape(d['used'])} / {html.escape(d['size'])}</td>
            <td>
                <div class="bar"><div class="fill" style="width:{pct}%;background:{bar_color}"></div></div>
                <span class="pct">{d['pct']}</span>
            </td>
        </tr>"""

    # SMART rows
    smart_rows = ""
    for s in smart:
        h_color = "#4caf50" if s["health"] == "OK" else "#f44336" if s["health"] == "FAIL" else "#999"
        r_color = "#4caf50" if s["realloc"] == "0" else "#f44336" if s["realloc"] else "#999"
        hours_str = ""
        if s["hours"]:
            try:
                h = int(s["hours"])
                hours_str = f"{h // 24 // 365}y" if h > 8760 else f"{h // 24}d"
            except ValueError:
                hours_str = s["hours"]
        smart_rows += f"""
        <tr>
            <td><code>/dev/{html.escape(s['dev'])}</code></td>
            <td style="color:{h_color}">{html.escape(s['health'])}</td>
            <td>{html.escape(s['temp'])}°C</td>
            <td>{hours_str}</td>
            <td style="color:{r_color}">{html.escape(s['realloc'])}</td>
        </tr>"""

    # Service rows
    svc_rows = ""
    for s in services:
        dot = '<span class="dot green"></span>' if s["running"] else '<span class="dot red"></span>'
        svc_rows += f'<div class="svc">{dot} {s["name"]}</div>'

    # RAID section
    raid_html = ""
    if raid_status:
        raid_html = f"""
        <div class="card">
            <h2>RAID 5</h2>
            <div class="stat">
                <span class="label">Status</span>
                <span class="value" style="color:{raid_color}">{raid_status}</span>
            </div>
            <div class="detail"><code>{html.escape(raid_detail or '')}</code></div>
            {'<div class="detail"><code>' + html.escape(raid_progress) + '</code></div>' if raid_progress else ''}
        </div>"""

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>{html.escape(hostname)} — NAS Dashboard</title>
<style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
       background: #1a1a2e; color: #e0e0e0; padding: 20px; }}
h1 {{ color: #fff; margin-bottom: 20px; font-size: 1.5em; }}
h1 span {{ color: #888; font-weight: normal; font-size: 0.7em; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }}
.card {{ background: #16213e; border-radius: 12px; padding: 20px; }}
.card h2 {{ color: #aaa; font-size: 0.85em; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; }}
.stat {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }}
.label {{ color: #888; }}
.value {{ font-size: 1.3em; font-weight: bold; }}
.detail {{ margin-top: 8px; }}
.detail code {{ color: #888; font-size: 0.8em; word-break: break-all; }}
table {{ width: 100%; border-collapse: collapse; }}
th {{ text-align: left; padding: 4px 8px; color: #666; font-weight: normal; font-size: 0.8em; border-bottom: 1px solid #253558; }}
td {{ padding: 6px 8px; border-bottom: 1px solid #1a1a2e; font-size: 0.9em; }}
.bar {{ background: #1a1a2e; border-radius: 4px; height: 8px; flex: 1; display: inline-block; width: 60%; vertical-align: middle; }}
.fill {{ height: 100%; border-radius: 4px; transition: width 0.3s; }}
.pct {{ font-size: 0.85em; color: #aaa; margin-left: 8px; }}
.dot {{ display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; }}
.green {{ background: #4caf50; }}
.red {{ background: #f44336; }}
.orange {{ background: #ff9800; }}
.svc {{ display: inline-block; margin-right: 20px; margin-bottom: 4px; }}
.backup {{ color: #888; font-size: 0.85em; margin-top: 10px; }}
.footer {{ text-align: center; color: #555; margin-top: 20px; font-size: 0.8em; }}
</style>
</head>
<body>
<h1>{html.escape(hostname)} <span>{' / '.join(ips)}</span></h1>
<div class="grid">
    <div class="card">
        <h2>System</h2>
        <div class="stat">
            <span class="label">Uptime</span>
            <span class="value">{uptime}</span>
        </div>
        <div class="stat">
            <span class="label">Temperature</span>
            <span class="value" style="color:{temp_color}">{temp_str}&deg;C</span>
        </div>
        <div class="stat">
            <span class="label">Load</span>
            <span class="value" style="font-size:1em">{load1} / {load5} / {load15}</span>
        </div>
        <div class="stat">
            <span class="label">RAM</span>
            <span class="value" style="font-size:1em">{mem_used}M / {mem_total}M</span>
        </div>
        <div class="stat">
            <span class="label"></span>
            <span>
                <div class="bar" style="width:100px"><div class="fill" style="width:{mem_pct}%;background:{mem_color}"></div></div>
                <span class="pct">{mem_pct}%</span>
            </span>
        </div>
        <div class="stat">
            <span class="label">Date</span>
            <span class="value" style="font-size:0.9em">{now}</span>
        </div>
    </div>

    {raid_html}

    <div class="card">
        <h2>Storage</h2>
        <table>{disk_rows}</table>
    </div>

    <div class="card">
        <h2>Disk Health (SMART)</h2>
        <table>
            <tr><th>Disk</th><th>Health</th><th>Temp</th><th>Age</th><th>Realloc</th></tr>
            {smart_rows}
        </table>
    </div>

    <div class="card">
        <h2>Services</h2>
        <div style="margin-top:8px">{svc_rows}</div>
        <div class="backup">Last backup: {html.escape(last_backup)}</div>
    </div>
</div>
<div class="footer">DNS-345 &middot; Debian Bookworm &middot; Kernel {html.escape(run('uname -r'))} &middot; Auto-refresh 30s</div>
</body>
</html>"""
    return page


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            content = render_page().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", len(content))
            self.end_headers()
            self.wfile.write(content)
        elif self.path == "/api/status":
            temp = get_temperature()
            raid_status, _, _ = get_raid_status()
            load1, load5, load15 = get_load()
            mem_total, mem_used, mem_pct = get_memory()
            data = json.dumps({
                "uptime": get_uptime(),
                "temp": temp,
                "load": [load1, load5, load15],
                "memory": {"total": mem_total, "used": mem_used, "pct": mem_pct},
                "raid": raid_status,
                "smart": get_smart(),
                "services": get_services(),
            })
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data.encode())
        else:
            self.send_error(404)

    def log_message(self, format, *args):
        pass  # silent


def main():
    parser = argparse.ArgumentParser(description="DNS-345 NAS Web Dashboard")
    parser.add_argument("--port", type=int, default=PORT, help=f"Port (default: {PORT})")
    parser.add_argument("--bind", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    args = parser.parse_args()

    server = http.server.HTTPServer((args.bind, args.port), DashboardHandler)
    print(f"DNS-345 Dashboard: http://{args.bind}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
