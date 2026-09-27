#!/usr/bin/env python3
"""
commit_seen.py — promote a run's item IDs into seen-state.

The runner calls this ONLY after the send succeeded (or was verified delivered).
Called any earlier, a failed send would hide today's items from tomorrow's run
and they would be lost silently.

Usage: commit_seen.py <ranked.json> <seen.json> [--cap N]
Atomic write (tmp + rename); keeps the most recent N ids (default 3000).
"""
import json
import os
import sys


def commit(ranked_path, seen_path, cap=3000):
    ids = []
    if os.path.exists(ranked_path):
        with open(ranked_path) as f:
            ids = [it["id"] for it in json.load(f).get("items", [])]
    seen = {"ids": []}
    if os.path.exists(seen_path):
        with open(seen_path) as f:
            seen = json.load(f)
    merged = list(dict.fromkeys(seen.get("ids", []) + ids))[-cap:]
    os.makedirs(os.path.dirname(os.path.abspath(seen_path)), exist_ok=True)
    tmp = seen_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"ids": merged}, f)
    os.replace(tmp, seen_path)
    return len(ids), len(merged)


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__, file=sys.stderr); sys.exit(1)
    cap = int(a[a.index("--cap") + 1]) if "--cap" in a else 3000
    added, total = commit(a[0], a[1], cap)
    print(f"seen-state: +{added} -> {total} total", file=sys.stderr)
