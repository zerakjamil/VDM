#!/usr/bin/env python3
import zipfile
import struct
import hashlib

FILEPATH = "/Users/zerakjamil/Downloads/Vortex Downloads/Grand Theft Auto V (USA Asia) (EnFrEsPtZhKo).zip.vortex"
z = zipfile.ZipFile(FILEPATH, "r")
info = z.infolist()[1]

with z.open(info) as f:
    # Read first 16 MB which contains all directory tables
    data = f.read(16 * 1024 * 1024)

# Parse PVD at sector 16 (offset 32768)
pvd = data[32768:32768+2048]
root_record = pvd[156:156+34]
root_extent = struct.unpack("<I", root_record[2:6])[0]
root_size = struct.unpack("<I", root_record[10:14])[0]
print(f"Root dir extent: sector {root_extent} (byte {root_extent * 2048}), size: {root_size}")

def parse_dir(extent, size, path=""):
    offset = extent * 2048
    dir_data = data[offset:offset+size]
    pos = 0
    files = []
    while pos < len(dir_data):
        length = dir_data[pos]
        if length == 0:
            pos = ((pos // 2048) + 1) * 2048
            continue
        record = dir_data[pos:pos+length]
        ext = struct.unpack("<I", record[2:6])[0]
        fsize = struct.unpack("<I", record[10:14])[0]
        flags = record[25]
        name_len = record[32]
        name = record[33:33+name_len].decode("latin1", "replace").split(";")[0]
        is_dir = (flags & 2) != 0
        if name not in ("\x00", "\x01"):
            cur_path = f"{path}/{name}" if path else name
            files.append((cur_path, ext, fsize, is_dir))
            if is_dir and ext * 2048 < len(data):
                files.extend(parse_dir(ext, fsize, cur_path))
        pos += length
    return files

all_files = parse_dir(root_extent, root_size)
print(f"Found {len(all_files)} entries in ISO:")
target_files = []
for p, ext, fsize, is_dir in all_files:
    if not is_dir and ("scaleform" in p.lower() or "common" in p.lower() or "rpf" in p.lower()):
        print(f"  FILE {p:45s} offset={ext*2048:12d} size={fsize:10d} ({fsize/1024**2:6.1f} MB)")
        target_files.append((p, ext * 2048, fsize))
