#!/usr/bin/env python3
"""Measure all processes in an app bundle without collecting connection arguments."""

import argparse
import ctypes
import json
import statistics
import subprocess
import time
from pathlib import Path

LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
LIBPROC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
LIBPROC.proc_pidpath.restype = ctypes.c_int


def cpu_seconds(value):
    days, _, clock = value.rpartition("-")
    parts = [float(part) for part in clock.split(":")]
    seconds = sum(part * 60 ** index for index, part in enumerate(reversed(parts)))
    return seconds + (int(days) * 86400 if days else 0)


def sample(bundle):
    output = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,time=,rss=,comm="], text=True
    )
    processes = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4:
            continue
        if parts[3].startswith("Contents/"):
            path = ctypes.create_string_buffer(4096)
            if LIBPROC.proc_pidpath(int(parts[0]), path, len(path)) > 0:
                parts[3] = path.value.decode("utf-8")
        if parts[3].startswith(str(bundle) + "/"):
            pid, cpu, rss, executable = parts
            processes[int(pid)] = {
                "name": Path(executable).name,
                "rssBytes": int(rss) * 1024,
                "cpuSeconds": cpu_seconds(cpu),
            }
    return processes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="App bundle to measure")
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--interval", type=float, default=2)
    args = parser.parse_args()
    if args.seconds <= 0 or args.interval <= 0:
        parser.error("seconds and interval must be positive")
    bundle = args.app.resolve(strict=True)
    start = sample(bundle)
    if not start:
        parser.error("no running processes from this app bundle")
    began = time.monotonic()
    samples = [sum(process["rssBytes"] for process in start.values())]
    current = start
    while time.monotonic() - began < args.seconds:
        time.sleep(min(args.interval, max(0, args.seconds - (time.monotonic() - began))))
        current = sample(bundle)
        if not current:
            parser.error("app exited during measurement")
        samples.append(sum(process["rssBytes"] for process in current.values()))
    elapsed = time.monotonic() - began
    cpu = sum(max(0, process["cpuSeconds"] - start.get(pid, {"cpuSeconds": 0})["cpuSeconds"])
              for pid, process in current.items())
    print(json.dumps({
        "metric": "sum of RSS; shared pages may be counted more than once",
        "durationSeconds": round(elapsed, 2),
        "samples": len(samples),
        "meanMB": round(statistics.mean(samples) / 1_000_000, 2),
        "minMB": round(min(samples) / 1_000_000, 2),
        "maxMB": round(max(samples) / 1_000_000, 2),
        "cpuPercentOfOneCore": round(cpu / elapsed * 100, 2),
        "finalProcesses": list(current.values()),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
