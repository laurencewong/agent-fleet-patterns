#!/usr/bin/env python3
"""
update_trust.py — outcome-learned source trust.

The engine multiplies each item's score by a per-source trust multiplier. This
script recomputes those multipliers from what the human actually did with past
items, so the system learns which sources produce things worth acting on.

Input: an outcomes log (JSONL), one row per surfaced item, e.g.
  {"date": "2026-07-20", "source": "Hacker News", "url": "...", "outcome": "acted"}
  outcome in {"acted", "ignored", "tossed"}. The reply handler that turns
  "build 1" / "toss 2" texts into these rows is the piece you wire yourself.

Rule: sources with >= MIN_N outcomes get
        mult = 0.85 + 0.6 * acted_rate, clamped to [0.7, 1.3]
      Fewer than MIN_N: left alone (no learning from two data points).
Deterministic, no LLM: this feeds ranking, so it must be explainable.

Usage: update_trust.py <outcomes.jsonl> <source-trust.json>
"""
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

MIN_N, BASE, SLOPE, LO, HI = 3, 0.85, 0.6, 0.7, 1.3


def compute(rows):
    stats = defaultdict(lambda: {"n": 0, "acted": 0})
    for r in rows:
        src = (r.get("source") or "unknown").split(":")[0].strip() or "unknown"
        if src == "unknown":
            continue
        stats[src]["n"] += 1
        stats[src]["acted"] += 1 if r.get("outcome") == "acted" else 0
    out = {}
    for src, s in stats.items():
        if s["n"] >= MIN_N:
            out[src] = round(max(LO, min(HI, BASE + SLOPE * s["acted"] / s["n"])), 3)
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr); return 1
    rows = []
    if os.path.exists(argv[0]):
        with open(argv[0]) as f:
            rows = [json.loads(l) for l in f if l.strip()]
    trust = {"sources": {}}
    if os.path.exists(argv[1]):
        with open(argv[1]) as f:
            trust = json.load(f)
    new = compute(rows)
    changed = [f"{k}={v}" for k, v in new.items() if trust.get("sources", {}).get(k) != v]
    trust.setdefault("sources", {}).update(new)
    trust["updated"] = datetime.now(timezone.utc).isoformat()
    tmp = argv[1] + ".tmp"
    with open(tmp, "w") as f:
        json.dump(trust, f, indent=2)
    os.replace(tmp, argv[1])
    print("trust: " + (", ".join(changed) or f"no change (sources need >= {MIN_N} outcomes)"),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
