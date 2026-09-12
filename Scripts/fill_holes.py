#!/usr/bin/env python3
"""
fill_holes.py
Directly downloads missing sparse holes in a .vortex file using HTTP Range requests
and writes them directly to their exact byte positions via POSIX pwrite.
"""

import os
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

FILE_PATH = "/Users/zerakjamil/Downloads/Vortex Downloads/Grand Theft Auto V (USA Asia) (EnFrEsPtZhKo).zip.vortex"
URL = "https://cdn.psgamedl.com/PS3-DEC/Grand%20Theft%20Auto%20V%20(USA%20Asia)%20(EnFrEsPtZhKo).zip?token=cHxcalNkXE9FFHVqUXYdYV9ZTRNydFB8Uw%3D%3D"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
    "Referer": "https://romsfun.com/",
}

def find_holes(filepath):
    stat = os.stat(filepath)
    size = stat.st_size
    fd = os.open(filepath, os.O_RDONLY)
    holes = []
    curr = 0
    try:
        while curr < size:
            try:
                hole_pos = os.lseek(fd, curr, os.SEEK_HOLE)
            except OSError:
                hole_pos = size
            if hole_pos >= size:
                break
            try:
                data_pos = os.lseek(fd, hole_pos, os.SEEK_DATA)
            except OSError:
                data_pos = size
            holes.append((hole_pos, data_pos - 1, data_pos - hole_pos))
            curr = data_pos
    finally:
        os.close(fd)
    return holes

def download_and_write(hole, fd):
    start, end, length = hole
    range_header = f"bytes={start}-{end}"
    headers = dict(HEADERS)
    headers["Range"] = range_header

    for attempt in range(5):
        try:
            req = urllib.request.Request(URL, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                if resp.status not in (200, 206):
                    raise RuntimeError(f"HTTP status {resp.status}")
                data = resp.read()
                if len(data) != length:
                    raise RuntimeError(f"Expected {length} bytes, got {len(data)}")
                os.pwrite(fd, data, start)
                return start, end, length, True
        except Exception as e:
            time.sleep(1 + attempt * 0.5)
            if attempt == 4:
                return start, end, length, False

def main():
    print(f"[+] Inspecting file: {FILE_PATH}")
    stat = os.stat(FILE_PATH)
    print(f"[+] Total size: {stat.st_size} bytes ({stat.st_size / 1024**3:.2f} GiB)")
    print(f"[+] Current allocated blocks: {stat.st_blocks} (~{stat.st_blocks * 512 / 1024**3:.2f} GiB)")

    holes = find_holes(FILE_PATH)
    total_missing = sum(h[2] for h in holes)
    print(f"[+] Found {len(holes)} holes totaling {total_missing} bytes ({total_missing / 1024**2:.2f} MiB)")

    if not holes:
        print("[✓] No holes found! File is already 100% complete.")
        return 0

    fd = os.open(FILE_PATH, os.O_RDWR)
    completed_bytes = 0
    t0 = time.time()

    print(f"[+] Launching multi-threaded downloader with 10 workers...")
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(download_and_write, h, fd): h for h in holes}
        for future in as_completed(futures):
            start, end, length, success = future.result()
            if success:
                completed_bytes += length
                pct = (completed_bytes / total_missing) * 100
                elapsed = max(0.1, time.time() - t0)
                speed = (completed_bytes / 1024**2) / elapsed
                print(f"  [✓] Written {start}..{end} ({length/1024:.1f} KB) - {completed_bytes/1024**2:.2f}/{total_missing/1024**2:.2f} MiB ({pct:.1f}%) @ {speed:.2f} MB/s", flush=True)
            else:
                print(f"  [✗] Failed to download {start}..{end} after 5 attempts!", file=sys.stderr)

    os.fsync(fd)
    os.close(fd)

    print(f"[+] Download phase finished in {time.time() - t0:.2f}s.")
    remaining_holes = find_holes(FILE_PATH)
    print(f"[+] Remaining holes: {len(remaining_holes)}")
    if remaining_holes:
        print(f"[!] Warning: {len(remaining_holes)} holes still remaining!")
        return 1
    else:
        new_stat = os.stat(FILE_PATH)
        print(f"[✓] SUCCESS! File is 100% physically complete on disk!")
        print(f"[✓] Allocated blocks: {new_stat.st_blocks} (~{new_stat.st_blocks * 512 / 1024**3:.2f} GiB)")
        return 0

if __name__ == "__main__":
    sys.exit(main())
