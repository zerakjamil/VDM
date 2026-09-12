#!/usr/bin/env python3
"""
repair_and_verify.py
Iteratively identifies any corrupt/missing deflate blocks in the zip archive,
fetches the exact authoritative bytes from the CDN via HTTP Range,
patches them in-place with POSIX pwrite, and verifies full decompression.
"""

import os
import sys
import time
import zipfile
import urllib.request
import urllib.error

FILEPATH = "/Users/zerakjamil/Downloads/Vortex Downloads/Grand Theft Auto V (USA Asia) (EnFrEsPtZhKo).zip.vortex"
URL = "https://cdn.psgamedl.com/PS3-DEC/Grand%20Theft%20Auto%20V%20(USA%20Asia)%20(EnFrEsPtZhKo).zip?token=cHxcalNkXE9FFHVqUXYdYV9ZTRNydFB8Uw%3D%3D"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
    "Referer": "https://romsfun.com/",
}

def fetch_and_patch(start_pos, end_pos, fd):
    start = max(0, start_pos)
    end = min(17274129115, end_pos)
    req_len = end - start + 1
    
    headers = dict(HEADERS)
    headers["Range"] = f"bytes={start}-{end}"
    
    for attempt in range(5):
        try:
            req = urllib.request.Request(URL, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                cdn_data = resp.read()
            if len(cdn_data) != req_len:
                raise RuntimeError(f"Length mismatch: got {len(cdn_data)}, expected {req_len}")
            
            disk_data = os.pread(fd, req_len, start)
            diffs = [i for i in range(req_len) if cdn_data[i] != disk_data[i]]
            if diffs:
                diff_count = len(diffs)
                os.pwrite(fd, cdn_data, start)
                os.fsync(fd)
                print(f"  [✓] Successfully patched {diff_count} differing bytes in range {start + diffs[0]}..{start + diffs[-1]}", flush=True)
                return True
            else:
                return False
        except Exception as e:
            time.sleep(1 + attempt * 0.5)
    return False

def main():
    print(f"[+] Starting repair & verify process on:\n    {FILEPATH}\n")
    fd = os.open(FILEPATH, os.O_RDWR)
    iteration = 0
    checkpoint = 0

    while True:
        iteration += 1
        print(f"\n--- [Iteration {iteration}] Checking decompression (checkpoint: {checkpoint / 1024**3:.2f} GiB) ---", flush=True)
        z = zipfile.ZipFile(FILEPATH, "r")
        info = z.infolist()[1]
        
        err_occurred = False
        err_msg = ""
        read_total = 0
        error_raw_pos = -1

        with z.open(info) as f:
            # Fast-forward to checkpoint - 16MB if possible
            seek_target = max(0, checkpoint - 16 * 1024 * 1024)
            while read_total < seek_target:
                chunk = min(16 * 1024 * 1024, seek_target - read_total)
                try:
                    f.read(chunk)
                    read_total += chunk
                except Exception as e:
                    err_occurred = True
                    err_msg = str(e)
                    error_raw_pos = f._fileobj.tell()
                    break
            
            if not err_occurred:
                # Normal reading in 8MB chunks
                while True:
                    try:
                        buf = f.read(8 * 1024 * 1024)
                        if not buf:
                            break
                        read_total += len(buf)
                        if read_total > checkpoint:
                            checkpoint = read_total
                        if read_total % (512 * 1024 * 1024) == 0:
                            print(f"  [+] Decompressed {read_total / 1024**3:.2f} / {info.file_size / 1024**3:.2f} GiB ({(read_total/info.file_size)*100:.1f}%)", flush=True)
                    except Exception as e:
                        err_occurred = True
                        err_msg = str(e)
                        error_raw_pos = f._fileobj.tell()
                        break
        
        z.close()

        if not err_occurred:
            print(f"\n🎉 [✓] 100% FULL ARCHIVE DECOMPRESSED WITH ZERO ERRORS!")
            print(f"    Total uncompressed size: {read_total} bytes ({read_total / 1024**3:.2f} GiB)")
            break

        print(f"  [!] Decompression error at uncompressed byte {read_total} ({read_total / 1024**3:.3f} GiB): {err_msg}", flush=True)
        print(f"  [!] Raw archive offset around: {error_raw_pos}", flush=True)

        # Search for diffs in a 2MB window around error_raw_pos
        patched = False
        for window in [256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024]:
            w_start = max(0, error_raw_pos - window)
            w_end = min(17274129115, error_raw_pos + window)
            if fetch_and_patch(w_start, w_end, fd):
                patched = True
                break
        
        if not patched:
            print(f"  [!] No differences found within 16MB window of {error_raw_pos}! Expanding search...", flush=True)
            # Try wider window before raw_pos
            w_start = max(0, error_raw_pos - 64 * 1024 * 1024)
            w_end = min(17274129115, error_raw_pos + 4 * 1024 * 1024)
            if not fetch_and_patch(w_start, w_end, fd):
                print(f"[✗] Could not find differing bytes around {error_raw_pos}. Aborting to prevent infinite loop.", file=sys.stderr)
                break

    os.close(fd)

if __name__ == "__main__":
    main()
