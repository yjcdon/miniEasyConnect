#!/usr/bin/env python3
"""Measure all processes in an app bundle without collecting connection arguments."""

import argparse
import ctypes
import json
import re
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


def sample(bundle, metric):
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
    if metric == "footprint" and processes:
        arguments = ["/usr/bin/top", "-l", "1", "-stats", "pid,mem"]
        for pid in processes:
            arguments.extend(["-pid", str(pid)])
        output = subprocess.check_output(arguments, text=True)
        footprints = {}
        for line in output.splitlines():
            match = re.fullmatch(r"\s*(\d+)\s+(\d+(?:\.\d+)?)([BKMGT]?)[+-]?\s*", line)
            if match:
                pid, value, unit = match.groups()
                footprints[int(pid)] = int(float(value) * 1024 ** {"": 0, "B": 0, "K": 1, "M": 2, "G": 3, "T": 4}[unit])
        if not processes.keys() <= footprints.keys():
            raise RuntimeError("Physical footprint unavailable for one or more current app processes")
        for pid, process in processes.items():
            process["footprintBytes"] = footprints[pid]
    return processes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="App bundle to measure")
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--interval", type=float, default=2)
    parser.add_argument("--metric", choices=("rss", "footprint"), default="rss")
    args = parser.parse_args()
    if args.seconds <= 0 or args.interval <= 0:
        parser.error("seconds and interval must be positive")
    bundle = args.app.resolve(strict=True)
    began = time.monotonic()
    start = sample(bundle, args.metric)
    if not start:
        parser.error("no running processes from this app bundle")
    memory_key = "rssBytes" if args.metric == "rss" else "footprintBytes"
    samples = [sum(process[memory_key] for process in start.values())]
    current = start
    while time.monotonic() - began < args.seconds:
        time.sleep(min(args.interval, max(0, args.seconds - (time.monotonic() - began))))
        current = sample(bundle, args.metric)
        if not current:
            parser.error("app exited during measurement")
        samples.append(sum(process[memory_key] for process in current.values()))
    elapsed = time.monotonic() - began
    cpu = sum(max(0, process["cpuSeconds"] - start.get(pid, {"cpuSeconds": 0})["cpuSeconds"])
              for pid, process in current.items())
    print(json.dumps({
        "metric": ("sum of RSS; shared pages may be counted more than once" if args.metric == "rss"
                   else "sum of physical footprints from top; rounded display, binary units"),
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
