#!/usr/bin/env python3
"""Averages the probe laps ('laps, ms per frame') of a log over a time window and prints the biggest.

    laps.py <log> [t0 t1] [N]     t0/t1: log seconds (default: all), N: how many to print (default 40)
"""
import re
import sys

log = sys.argv[1]
t0 = float(sys.argv[2]) if len(sys.argv) > 3 else 0.0
t1 = float(sys.argv[3]) if len(sys.argv) > 3 else 1e9
top = int(sys.argv[4]) if len(sys.argv) > 4 else (int(sys.argv[2]) if len(sys.argv) == 3 else 40)
sums, counts, n = {}, {}, 0
other = {}
for line in open(log, errors="replace"):
    m = re.match(r"\[([\d.]+)\] VitaRenderDevice: (laps, ms per frame|ticks by class, ms per frame|draw nodes by step, ms per game frame|engine parts, ms per game frame)[^:]*: (.*)", line)
    if not m or not (t0 <= float(m.group(1)) <= t1):
        continue
    kind = m.group(2)
    if kind.startswith("laps"):
        n += 1
        for it in re.finditer(r"([^;]+?) ([\d.]+) \(([\d.]+) x (\d+)\)", m.group(3)):
            k = it.group(1).strip()
            sums[k] = sums.get(k, 0.0) + float(it.group(2))
            counts[k] = counts.get(k, 0.0) + float(it.group(3)) * 0 + int(it.group(4))
    else:
        for it in re.finditer(r"([A-Za-z][A-Za-z /]*?) ([\d.]+)", m.group(3)):
            key = kind.split(",")[0] + ": " + it.group(1).strip()
            other.setdefault(key, []).append(float(it.group(2)))
print(f"{n} lap lines")
for k, v in sorted(sums.items(), key=lambda kv: -kv[1])[:top]:
    print(f"  {v / n:6.2f} ms  {counts[k] / n:8.1f} calls  {k}")
for k, v in other.items():
    if k.startswith(("engine parts", "draw nodes")):
        print(f"  {sum(v) / len(v):6.2f} ms  {k}")
