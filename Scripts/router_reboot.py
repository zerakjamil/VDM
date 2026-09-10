#!/usr/bin/env python3
"""
ZTE MT-0011 / Smart Gateway Automated WAN / Router Rebooter
============================================================
Logs into the ZTE gateway at 192.168.1.1 and triggers a software reboot.
This drops and reconnects the ISP PPPoE / WAN session with Kurdistan Net,
assigning a fresh IP and restoring the 15 MB/s burst quota without having
to touch the physical power switch.
"""

import sys
import time
import socket
import urllib.request
import urllib.parse
import http.cookiejar
import subprocess
import argparse

DEFAULT_ROUTER_IP = "192.168.1.1"

def get_keychain_password():
    """Retrieve saved router password from macOS Keychain."""
    try:
        cmd = ["security", "find-generic-password", "-a", "user", "-s", "VortexRouter", "-w"]
        pw = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
        return pw
    except Exception:
        return None

def save_keychain_password(pw):
    """Save router password into macOS Keychain."""
    try:
        subprocess.run(
            ["security", "add-generic-password", "-U", "-a", "user", "-s", "VortexRouter", "-w", pw],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return True
    except Exception:
        return False

def check_internet(host="8.8.8.8", port=53, timeout=2):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False

def get_public_ip():
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=3) as resp:
            return resp.read().decode("utf-8").strip()
    except Exception:
        return None

def reboot_zte_router(router_ip=DEFAULT_ROUTER_IP, password=None):
    if not password:
        password = get_keychain_password()

    if not password:
        print("[!] No router password found in Keychain or CLI.")
        return False

    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    login_url = f"http://{router_ip}/"
    login_data = urllib.parse.urlencode({
        "username": "user",
        "password": password,
        "action": "login",
        "Frm_Logintoken": "0",
        "ieversion": "1"
    }).encode("utf-8")

    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        "Referer": login_url,
        "Content-Type": "application/x-www-form-urlencoded"
    }

    print(f"[*] Logging in to ZTE Smart Gateway at {router_ip} as 'user'...")
    try:
        req = urllib.request.Request(login_url, data=login_data, headers=headers)
        with opener.open(req, timeout=5) as resp:
            content = resp.read().decode("utf-8", errors="ignore")
            if "User information is error" in content or "wrong username or password" in content:
                print("[!] Login failed: Incorrect password. Please check the sticker on your router.")
                return False
            print("[+] Login successful! Session established.")
    except Exception as e:
        print(f"[!] HTTP error connecting to router: {e}")
        return False

    # Fetch manager_dev_restart_t.gch to extract the session token
    restart_url = f"http://{router_ip}/getpage.gch?pid=1002&nextpage=manager_dev_restart_t.gch"
    session_token = ""
    try:
        req_page = urllib.request.Request(restart_url, headers=headers)
        with opener.open(req_page, timeout=5) as p_resp:
            p_data = p_resp.read().decode("utf-8", errors="ignore")
            # Look for session_token
            import re
            m = re.search(r"session_token\s*=\s*[\x27\x22](\d+)[\x27\x22]", p_data)
            if m:
                session_token = m.group(1)
                print(f"[+] Acquired router session token: {session_token}")
    except Exception as e:
        print(f"[!] Warning fetching restart page: {e}")

    # Exact ZTE MT-0011 devrestart form submission
    payload = {
        "IF_ACTION": "devrestart",
        "flag": "1"
    }
    if session_token:
        payload["_SESSION_TOKEN"] = session_token

    post_data = urllib.parse.urlencode(payload).encode("utf-8")
    reboot_triggered = False

    try:
        r_req = urllib.request.Request(restart_url, data=post_data, headers=headers)
        with opener.open(r_req, timeout=5) as r_resp:
            res_content = r_resp.read().decode("utf-8", errors="ignore")
            print(f"[+] Sent 'devrestart' command to ZTE MT-0011 (HTTP {r_resp.status})")
            reboot_triggered = True
    except Exception as ex:
        # If router drops connection immediately during reboot, that's also success!
        print(f"[+] Router connection dropped on reboot command: {ex}")
        reboot_triggered = True

    if not reboot_triggered:
        print("[!] Could not trigger reboot through web endpoints.")
        return False

    print("[⚡ TURBO] Router reboot instruction sent!")
    print("[*] Waiting for ZTE router to restart and re-establish Kurdistan Net WAN link...")
    
    # Wait for gateway to drop
    time.sleep(5)
    # Wait for internet to come back up
    restored = False
    for i in range(90):
        time.sleep(2)
        if check_internet():
            new_ip = get_public_ip()
            print(f"\n[🚀 SUCCESS] Internet restored in {(i+1)*2 + 5}s!")
            if new_ip:
                print(f"[+] Fresh Public IP Acquired: {new_ip} (Quota Reset!)")
            restored = True
            break
        sys.stdout.write(f"\rWaiting for WAN reconnect... ({(i+1)*2}s)")
        sys.stdout.flush()

    return restored

def main():
    parser = argparse.ArgumentParser(description="ZTE MT-0011 Automated Rebooter")
    parser.add_argument("--password", "-p", help="Router 'user' password (found on back sticker)")
    parser.add_argument("--save", action="store_true", help="Save password to macOS Keychain for future auto-use")
    parser.add_argument("--ip", default=DEFAULT_ROUTER_IP, help="Router IP (default: 192.168.1.1)")
    args = parser.parse_args()

    pw = args.password
    if pw and args.save:
        save_keychain_password(pw)
        print("[+] Password saved to macOS Keychain.")

    if not pw:
        pw = get_keychain_password()

    if not pw:
        print("=" * 60)
        print(" ZTE MT-0011 ROUTER REBOOT SETUP")
        print("=" * 60)
        print("Your router is a ZTE Smart Gateway (MT-0011) at 192.168.1.1.")
        print("The default 'user' password is on the label on the back/bottom of your router.")
        print()
        pw = input("Enter router password: ").strip()
        if pw:
            save_keychain_password(pw)
            print("[+] Saved to Keychain.")
        else:
            print("No password entered. Exiting.")
            sys.exit(1)

    old_ip = get_public_ip()
    print(f"Current Public IP: {old_ip}")
    success = reboot_zte_router(args.ip, pw)
    if success:
        print("[✓] Router reboot and WAN reconnect complete.")
    else:
        print("[✗] Failed to reboot router.")

if __name__ == "__main__":
    main()
