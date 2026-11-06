#!/usr/bin/env python3
"""Turns ux0:data/flipendo/profile.txt (from a -DVITA_PROFILE=ON build) into a list of functions.

Usage (in WSL):  ./resolve_profile.py profile.txt ~/flipendo/vita/build-profile/flipendo
"""
import re
import subprocess
import sys
from collections import defaultdict

if len(sys.argv) != 3:
    sys.exit(__doc__)
profile, elf = sys.argv[1], sys.argv[2]

# where the marker function lies in the file
nm = subprocess.run(["arm-vita-eabi-nm", elf], capture_output=True, text=True).stdout
marker_elf = None
for line in nm.splitlines():
    parts = line.split()
    if len(parts) == 3 and parts[2] == "VitaProfileMarker":
        marker_elf = int(parts[0], 16) & ~1
if marker_elf is None:
    sys.exit("VitaProfileMarker is not in " + elf + ": is this the profiling build?")

dumps = []
for line in open(profile):
    line = line.strip()
    m = re.match(r"dump marker=(0x[0-9a-f]+) samples=(\d+)", line)
    if m:
        dumps.append({"marker": int(m.group(1), 16), "samples": int(m.group(2)), "items": []})
    elif line.startswith("0x") and dumps:
        a, c = line.split()
        dumps[-1]["items"].append((int(a, 16), int(c)))

for number, dump in enumerate(dumps, 1):
    if not dump["items"]:
        continue
    addresses = [marker_elf + (a - dump["marker"]) for a, c in dump["items"]]
    out = subprocess.run(["arm-vita-eabi-addr2line", "-f", "-C", "-e", elf] + [hex(a) for a in addresses],
                         capture_output=True, text=True).stdout.splitlines()
    names = out[0::2]
    per_function = defaultdict(int)
    for (a, c), name in zip(dump["items"], names):
        per_function[name] += c
    total = dump["samples"] or 1
    print("=== dump %d: %d samples (about %d ms of the engine thread) ===" % (number, dump["samples"], dump["samples"]))
    for name, count in sorted(per_function.items(), key=lambda x: -x[1])[:30]:
        print("%5.1f%%  %s" % (100.0 * count / total, name[:130]))
    print()
