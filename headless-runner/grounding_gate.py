#!/usr/bin/env python3
"""
grounding_gate.py — deterministic check that an LLM draft invents no numbers
or links.

Every number and every URL in the draft must appear in the facts file the
model was given. The prompt already says "use only numbers in the facts". This
gate is there because a prompt is a request, not an invariant: a draft that
says "3,400 stars" when the facts say 340 is worse than no draft.

Normalization: thousands separators are stripped ("3,400" == "3400"), and
k/m suffixes are expanded ("12k" -> 12000, "1.2M" -> 1200000) on both sides,
so "12k" in the draft matches 12000 or "12k" in the facts. Small integers
(<= SMALL_OK, default 10) are allowed freely: list markers, "2 things",
"top 3". That is a deliberate hole. Tighten it with --small 0.

Exit 0 = grounded. Exit 1 = ungrounded (offending tokens listed on stderr).
Usage: grounding_gate.py <draft.txt> <facts.md> [--small N]
"""
import re
import sys

URL_RE = re.compile(r"https?://[^\s)>\]\"']+")
NUM_RE = re.compile(r"(?<![\w.])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*([kKmM])?(?![\w])")
# Facts side is extracted loosely ("5.5h old", "305pts") so the gate errs
# toward accepting a number that genuinely is in the facts.
NUM_LOOSE = re.compile(r"(?<![\d.,])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)([kKmM](?![a-zA-Z]))?")


def urls(text):
    return {u.rstrip(".,;:!?") for u in URL_RE.findall(text)}


def numbers(text, loose=False):
    text = URL_RE.sub(" ", text)                 # digits inside URLs aren't claims
    out = set()
    for raw, suf in (NUM_LOOSE if loose else NUM_RE).findall(text):
        v = float(raw.replace(",", ""))
        if suf:
            v *= 1_000 if suf.lower() == "k" else 1_000_000
        out.add(round(v, 4))
    return out


def check(draft, facts, small_ok=10):
    bad_urls = sorted(u for u in urls(draft) if u not in facts)
    fact_nums = numbers(facts, loose=True)
    bad_nums = sorted(n for n in numbers(draft)
                      if n not in fact_nums and not (n == int(n) and 0 <= n <= small_ok))
    return bad_nums, bad_urls


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    small = int(argv[argv.index("--small") + 1]) if "--small" in argv else 10
    draft = open(argv[0], encoding="utf-8").read()
    facts = open(argv[1], encoding="utf-8").read()
    # Header dates are the one legit number source outside the facts.
    import datetime
    d = datetime.date.today()
    facts += f"\n{d.day} {d.year} {d.month}"
    bad_nums, bad_urls = check(draft, facts, small)
    if bad_nums or bad_urls:
        if bad_nums:
            print("grounding: numbers not in facts: " + ", ".join(f"{n:g}" for n in bad_nums), file=sys.stderr)
        if bad_urls:
            print("grounding: urls not in facts: " + ", ".join(bad_urls), file=sys.stderr)
        return 1
    print("grounding: ok", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
