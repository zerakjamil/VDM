#!/usr/bin/env python3
"""
Vortex Auto-Turbo Daemon
=========================
Monitors Vortex Download Manager in real time. When ISP / CDN bandwidth shaping
throttles download throughput from ~15 MB/s down to 3.x MB/s, this daemon automatically:
1. Recycles TCP connections with fresh sockets via Vortex IPC (/recycle).
2. If router NAT / ISP quota has locked the interface, safely pauses Vortex,
   bounces the Wi-Fi connection, waits for link reconnection, and resumes
   the download without user intervention.
"""

import sys
import time
import json
import socket
import argparse
import subprocess
import urllib.request
import urllib.error
import os

try:
    from router_reboot import reboot_zte_router, get_keychain_password
except ImportError:
    # If executed from outside Scripts directory
    sys.path.append(os.path.dirname(os.path.abspath(__file__)))
    from router_reboot import reboot_zte_router, get_keychain_password

VORTEX_IPC_URL = "http://127.0.0.1:17890"

def get_wifi_interface():
    """Detect the hardware device name for Wi-Fi (e.g. en0) via networksetup."""
    try:
        output = subprocess.check_output(["networksetup", "-listallhardwareports"], text=True)
        lines = output.splitlines()
        found_wifi = False
        for line in lines:
            if "Hardware Port: Wi-Fi" in line or "Hardware Port: AirPort" in line:
                found_wifi = True
            elif found_wifi and "Device:" in line:
                dev = line.split("Device:")[1].strip()
                return dev
            elif found_wifi and "Hardware Port:" in line:
                found_wifi = False
    except Exception as e:
        print(f"[!] Warning: Could not detect Wi-Fi interface: {e}")
    return "en0"

def check_internet(host="8.8.8.8", port=53, timeout=3):
    """Check if internet connectivity is restored."""
    try:
        socket.setdefaulttimeout(timeout)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect((host, port))
        return True
    except Exception:
        return False

def post_vortex(endpoint, payload=None):
    """Send a POST command to Vortex IPC server."""
    url = f"{VORTEX_IPC_URL}{endpoint}"
    data = json.dumps(payload or {}).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=4) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return None

def get_vortex_status():
    """Fetch active download tasks from Vortex."""
    url = f"{VORTEX_IPC_URL}/downloads"
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return None

def bounce_wifi(interface):
    """Toggle Wi-Fi power off and on to force a new DHCP lease / NAT session."""
    print(f"\n[⚡ TURBO] Bouncing Wi-Fi interface '{interface}' to refresh ISP quota...")
    try:
        subprocess.run(["networksetup", "-setairportpower", interface, "off"], check=True)
        time.sleep(1.5)
        subprocess.run(["networksetup", "-setairportpower", interface, "on"], check=True)
        print(f"[⚡ TURBO] Wi-Fi powered on. Waiting for internet connection to re-establish...")

        for i in range(20):
            time.sleep(1.0)
            if check_internet():
                print(f"[⚡ TURBO] Connection re-established in {i + 1}s!")
                return True
        print("[!] Warning: Connection restoration timed out after 20s.")
        return False
    except subprocess.CalledProcessError as e:
        print(f"[!] Failed to toggle Wi-Fi: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Vortex Auto-Turbo Bandwidth Restorer")
    parser.add_argument("--interface", default=None, help="Wi-Fi interface (default: auto-detected, e.g. en0)")
    parser.add_argument("--threshold-mb", type=float, default=3.8, help="Speed drop threshold in MB/s (default: 3.8)")
    parser.add_argument("--peak-mb", type=float, default=7.0, help="Minimum peak speed in MB/s to qualify for throttling (default: 7.0)")
    parser.add_argument("--throttle-time", type=int, default=6, help="Seconds throttled before taking action (default: 6)")
    parser.add_argument("--cooldown", type=int, default=30, help="Cooldown in seconds between Wi-Fi bounces (default: 30)")
    parser.add_argument("--recycle-only", action="store_true", help="Only recycle TCP sockets, do not bounce Wi-Fi")
    parser.add_argument("--now", action="store_true", help="Trigger turbo session refresh immediately on the active download")
    parser.add_argument("--router-reboot", action="store_true", help="Reboot ZTE router (192.168.1.1) to reset ISP burst quota")
    parser.add_argument("--router-ip", default="192.168.1.1", help="Router IP address (default: 192.168.1.1)")
    parser.add_argument("--router-pass", default=None, help="ZTE router user password (from back sticker)")
    args = parser.parse_args()

    router_pw = args.router_pass or get_keychain_password()
    use_router_reboot = args.router_reboot or (router_pw is not None)

    interface = args.interface or get_wifi_interface()
    threshold_bytes = args.threshold_mb * 1024 * 1024
    peak_bytes = args.peak_mb * 1024 * 1024

    print("=" * 65)
    print(" 🚀 VORTEX AUTO-TURBO BANDWIDTH MONITOR")
    print("=" * 65)
    print(f" • Wi-Fi Interface    : {interface}")
    print(f" • Peak Speed Trigger : {args.peak_mb:.1f} MB/s")
    print(f" • Throttle Threshold : {args.threshold_mb:.1f} MB/s")
    print(f" • Throttle Duration  : {args.throttle_time} seconds")
    print(f" • Mode               : {'TCP Socket Recycle Only' if args.recycle_only else 'Hybrid (TCP Recycle + Wi-Fi Bounce)'}")
    print("=" * 65)
    print("Connecting to Vortex Download Manager...")

    peak_speed_seen = 0.0
    throttled_since = None
    last_bounce_time = 0.0
    force_trigger = args.now

    while True:
        try:
            tasks = get_vortex_status()
            if tasks is None:
                sys.stdout.write("\r[Vortex Offline] Vortex is not running. Retrying in 3s...       ")
                sys.stdout.flush()
                time.sleep(3)
                continue

            active_tasks = [t for t in tasks if t.get("status") in ("downloading", "connecting")]

            if not active_tasks:
                peak_speed_seen = 0.0
                throttled_since = None
                sys.stdout.write("\r[Vortex Idle] No active downloads running. Waiting...            ")
                sys.stdout.flush()
                time.sleep(2)
                continue

            total_speed = sum(t.get("currentSpeed") or t.get("speed") or 0.0 for t in active_tasks)
            current_mb = total_speed / (1024 * 1024)

            if total_speed > peak_speed_seen:
                peak_speed_seen = total_speed

            peak_mb = peak_speed_seen / (1024 * 1024)
            main_task = active_tasks[0]
            task_name = main_task.get("fileName") or main_task.get("filename") or main_task.get("name") or "File"
            if len(task_name) > 24:
                task_name = task_name[:21] + "..."

            status_msg = f"\r[{task_name}] Speed: {current_mb:5.1f} MB/s | Peak: {peak_mb:5.1f} MB/s"
            now = time.time()

            # Check if throttled or force triggered
            is_throttled = (peak_speed_seen >= peak_bytes and total_speed < threshold_bytes) or force_trigger
            if is_throttled:
                if throttled_since is None:
                    throttled_since = now
                duration = int(now - throttled_since) if not force_trigger else args.throttle_time
                status_msg += f" | THROTTLED ({duration}s/{args.throttle_time}s)"
                sys.stdout.write(status_msg)
                sys.stdout.flush()

                if duration >= args.throttle_time or force_trigger:
                    force_trigger = False
                    print(f"\n[!] Throttling sustained! (Speed: {current_mb:.1f} MB/s vs Peak: {peak_mb:.1f} MB/s)")

                    # Step 1: In-app socket recycling
                    print("  ➜ Step 1: Recycling TCP connections in Vortex with fresh sockets...")
                    recycle_resp = post_vortex("/recycle")
                    recycled_ok = False
                    if recycle_resp and not recycle_resp.get("error"):
                        time.sleep(5)
                        check_tasks = get_vortex_status() or []
                        check_speed = sum(t.get("currentSpeed") or t.get("speed") or 0.0 for t in check_tasks if t.get("status") in ("downloading", "connecting"))
                        check_mb = check_speed / (1024 * 1024)
                        if check_speed >= threshold_bytes * 1.5:
                            print(f"  ✅ [RESTORED] Speed jumped to {check_mb:.1f} MB/s via connection recycling!")
                            throttled_since = None
                            peak_speed_seen = check_speed
                            recycled_ok = True
                            continue

                    # Step 2: Automated Router Reboot (WAN reconnect) OR Wi-Fi Bounce
                    if not recycled_ok and (now - last_bounce_time) > args.cooldown:
                        post_vortex("/pause")
                        time.sleep(0.5)

                        if use_router_reboot and router_pw:
                            print(f"  ➜ Step 2: Quota exhausted. Sending automated reboot to ZTE Gateway at {args.router_ip}...")
                            success = reboot_zte_router(router_ip=args.router_ip, password=router_pw)
                        elif not args.recycle_only:
                            print(f"  ➜ Step 2: Refreshing Wi-Fi interface session (bouncing '{interface}')...")
                            success = bounce_wifi(interface)
                        else:
                            success = False

                        last_bounce_time = time.time()
                        print("  ➜ Resuming Vortex downloads with fresh session...")
                        post_vortex("/resume")
                        throttled_since = None
                        peak_speed_seen = 0.0 # Reset peak to establish fresh baseline
                        time.sleep(3)
                        continue
                    else:
                        throttled_since = None
            else:
                throttled_since = None
                status_msg += " | OK                 "
                sys.stdout.write(status_msg)
                sys.stdout.flush()

            time.sleep(2)
        except KeyboardInterrupt:
            print("\nExiting Vortex Auto-Turbo Daemon.")
            break
        except Exception as ex:
            print(f"\n[!] Error in monitor loop: {ex}")
            time.sleep(2)

if __name__ == "__main__":
    main()
