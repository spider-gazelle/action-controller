#!/usr/bin/env python3
"""Print grouped medians from bench/run.py raw JSON."""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: python3 bench/report.py RESULTS.json")
runs = json.loads(Path(sys.argv[1]).read_text())["runs"]
groups = defaultdict(list)
for run in runs:
    data = run["result"]
    codes = data["statusCodeDistribution"]
    unexpected = {key: value for key, value in codes.items() if key != "200" and value}
    errors = {key: value for key, value in data["errorDistribution"].items()
              if key != "aborted due to deadline" and value}
    if unexpected or errors or data["summary"]["successRate"] < 1:
        raise SystemExit(f"invalid run: {run['mode']} {run['path']}: {unexpected} {errors}")
    groups[(run["path"], run["mode"])].append(data)
print("path         mode               runs  median req/s  median p99 ms")
for (path, mode), samples in sorted(groups.items()):
    rps = statistics.median(sample["summary"]["requestsPerSec"] for sample in samples)
    p99 = statistics.median(sample["latencyPercentiles"]["p99"] * 1000 for sample in samples)
    print(f"{path:12} {mode:18} {len(samples):>4}  {rps:>12,.0f}  {p99:>13.3f}")
