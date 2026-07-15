#!/usr/bin/env python3
"""eval-ts-match.py — check if a run-id epoch has a matching entry in
subagent-runs.jsonl within a ±60 min window.

Usage: eval-ts-match.py <run_epoch> <jsonl_path>
Exit 0 + prints "1" = match found.
Exit 1 + prints "0" = no match.
"""
import json, sys
from datetime import datetime, timezone

if len(sys.argv) != 3:
    print("Usage: eval-ts-match.py <run_epoch> <jsonl_path>", file=sys.stderr)
    sys.exit(2)

run_epoch = int(sys.argv[1])
jsonl_path = sys.argv[2]

WINDOW = 3600  # ±60 minutes in seconds

with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        ts = entry.get("ts", "")
        if not ts:
            continue
        try:
            dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            entry_epoch = int(dt.timestamp())
        except (ValueError, TypeError):
            continue
        diff = abs(entry_epoch - run_epoch)
        if diff <= WINDOW:
            print("1")
            sys.exit(0)

print("0")
sys.exit(1)
