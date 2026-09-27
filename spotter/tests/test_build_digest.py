"""Offline tests for the spotter engine (no network). Run: python3 -m unittest discover spotter/tests"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "engine"))
import build_digest as bd  # noqa: E402
import commit_seen  # noqa: E402
import update_trust  # noqa: E402

NOW = 1_800_000_000.0
PROFILE = os.path.join(HERE, "..", "profiles", "ai-dev-tooling.yaml")


def prof():
    return {
        "name": "Test", "title": "Test Radar", "maxItems": 5, "maxAgeDays": 7,
        "freshWindowHours": 48, "starsAsSentiment": True,
        "beats": {
            "breakage": {"weight": 1.4, "lean": "negative",
                         "coOccur": [["cursor", "mcp"], ["outage", "broken"]]},
            "agents": {"weight": 1.5, "terms": ["ai agent", "ai", "mcp", "subagent"]},
            "guides": {"weight": 1.3, "terms": ["tutorial", "guide"]},
        },
        "signal": {"minRelevance": 0.5},
    }


def item(text, age_h=1, source="Hacker News", url=None, eng=None):
    return {"source": source, "url": url or f"https://example.com/{abs(hash(text))}",
            "text": text, "created_ts": NOW - age_h * 3600,
            "eng": eng if eng is not None else {"points": 100, "comments": 20}}


class Matching(unittest.TestCase):
    def test_word_boundary(self):
        self.assertEqual(bd.match_terms("my hair salon said hi", ["ai"]), [])
        self.assertEqual(bd.match_terms("An AI agent ships", ["ai"]), ["ai"])
        self.assertEqual(bd.match_terms("written in c++ today", ["c++"]), ["c++"])

    def test_cooccur_requires_every_group_and_wins_first(self):
        beat, hits = bd.classify(item("MCP server broken after update"), prof())
        self.assertEqual(beat, "breakage")
        self.assertIn("mcp", hits); self.assertIn("broken", hits)
        beat, _ = bd.classify(item("New MCP server released"), prof())
        self.assertEqual(beat, "agents")

    def test_most_hits_wins_ties_go_to_earlier_beat(self):
        self.assertEqual(bd.classify(item("a tutorial and a guide, one subagent"), prof())[0], "guides")
        self.assertEqual(bd.classify(item("subagent tutorial"), prof())[0], "agents")   # 1-1 tie

    def test_unmatched_item_has_no_beat(self):
        self.assertEqual(bd.classify(item("weather is nice"), prof()), (None, []))


class Sentiment(unittest.TestCase):
    def test_lexicon(self):
        neg, hits = bd.negativity("it is broken and slow, total regression")
        self.assertEqual(neg, 1.0); self.assertEqual(len(hits), 3)

    def test_stars_override_words(self):
        p = {"starsAsSentiment": True}
        self.assertEqual(bd.negativity("X app review [5/5 stars]: I hate how much I love it", p)[0], 0.0)
        self.assertEqual(bd.negativity("X app review [1/5 stars]: fine", p)[0], 1.0)
        self.assertEqual(bd.negativity("X app review [3/5 stars]: ok", p)[0], 0.5)

    def test_negative_lean_boosts_only_that_beat(self):
        a = bd.score(item("cursor outage broken regression"), prof(), NOW)
        p2 = prof(); p2["beats"]["breakage"].pop("lean")
        b = bd.score(item("cursor outage broken regression"), p2, NOW)
        self.assertGreater(a["score"], b["score"])


class Ranking(unittest.TestCase):
    def test_recency_ranks_but_does_not_gate(self):
        fresh = item("ai agent subagent mcp", age_h=1, url="https://e.com/fresh")
        old = item("ai agent subagent mcp", age_h=100, url="https://e.com/old")
        picked, _ = bd.rank([old, fresh], prof(), set(), NOW)
        self.assertEqual([i["url"] for i in picked], ["https://e.com/fresh", "https://e.com/old"])

    def test_max_age_is_the_hard_cut(self):
        picked, _ = bd.rank([item("ai agent mcp", age_h=24 * 8)], prof(), set(), NOW)
        self.assertEqual(picked, [])

    def test_seen_state_dedups(self):
        it = item("ai agent mcp", url="https://e.com/a")
        seen = {bd.item_id("https://e.com/a", "")}
        self.assertEqual(bd.rank([it], prof(), seen, NOW)[0], [])

    def test_tracking_params_do_not_defeat_dedup(self):
        self.assertEqual(bd.item_id("https://E.com/a?utm_source=x&id=1", ""),
                         bd.item_id("https://e.com/a?id=1", ""))

    def test_duplicate_story_kept_once(self):
        a = item("ai agent mcp", url="https://e.com/same")
        b = item("ai agent mcp subagent", url="https://e.com/same")
        self.assertEqual(len(bd.rank([a, b], prof(), set(), NOW)[0]), 1)

    def test_source_trust_multiplier(self):
        p = prof(); p["_sourceTrust"] = {"GitHub": 1.3, "Hacker News": 0.7}
        hn = item("ai agent mcp", source="Hacker News", url="https://e.com/hn")
        gh = item("ai agent mcp", source="GitHub", url="https://e.com/gh", eng={"points": 100, "comments": 20})
        picked, _ = bd.rank([hn, gh], p, set(), NOW)
        self.assertEqual(picked[0]["url"], "https://e.com/gh")

    def test_beat_diversity_cap(self):
        p = prof(); p["maxItems"] = 5                     # cap = 3 per beat
        agents = [item(f"ai agent mcp subagent {i}", url=f"https://e.com/a{i}") for i in range(6)]
        guides = [item(f"tutorial guide {i}", url=f"https://e.com/g{i}", eng={}) for i in range(2)]
        picked, pool = bd.rank(agents + guides, p, set(), NOW)
        beats = [i["beat"] for i in picked]
        self.assertEqual(beats.count("agents"), 3); self.assertEqual(beats.count("guides"), 2)

    def test_below_floor_dropped(self):
        p = prof(); p["signal"]["minRelevance"] = 0.99
        self.assertEqual(bd.rank([item("ai agent")], p, set(), NOW)[0], [])


class EndToEnd(unittest.TestCase):
    def test_main_writes_facts_and_quiet_day_exit(self):
        d = tempfile.mkdtemp()
        seen = os.path.join(d, "seen.json")
        feed = lambda p, now: [item("New AI agents framework with MCP support", url="https://e.com/x")]
        failing = lambda p, now: 1 / 0          # one source crashing must not abort the run
        rc = bd.main([PROFILE, d, seen], fetchers=[failing, feed], now=NOW)
        self.assertEqual(rc, 0)
        facts = open(os.path.join(d, "ai-dev-tooling-facts.md")).read()
        self.assertIn("https://e.com/x", facts)
        # promote, then the same item is a quiet day
        commit_seen.commit(os.path.join(d, "ai-dev-tooling-ranked.json"), seen)
        self.assertEqual(bd.main([PROFILE, d, seen], fetchers=[feed], now=NOW), 3)

    def test_feed_parser_rss_and_atom(self):
        rss = b"<rss><channel><title>T</title><item><title>A</title><link>https://e.com/a</link><description>d</description><pubDate>Tue, 01 Jul 2025 10:00:00 GMT</pubDate></item></channel></rss>"
        atom = b'<feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><entry><title>B</title><link href="https://e.com/b"/><updated>2025-07-01T10:00:00Z</updated></entry></feed>'
        self.assertEqual(bd._parse_feed(rss)[1][0]["link"], "https://e.com/a")
        self.assertEqual(bd._parse_feed(atom)[1][0]["link"], "https://e.com/b")
        self.assertGreater(bd._parse_date("Tue, 01 Jul 2025 10:00:00 GMT"), 0)


class Trust(unittest.TestCase):
    def test_needs_min_outcomes_and_clamps(self):
        rows = ([{"source": "GitHub", "outcome": "acted"}] * 4
                + [{"source": "RSS: Some Blog", "outcome": "ignored"}] * 5
                + [{"source": "Hacker News", "outcome": "acted"}] * 2)
        t = update_trust.compute(rows)
        self.assertEqual(t["GitHub"], 1.3)          # 0.85 + 0.6 = 1.45 -> clamped
        self.assertEqual(t["RSS"], 0.85)            # 0 acted -> base
        self.assertNotIn("Hacker News", t)          # only 2 outcomes: no learning yet


if __name__ == "__main__":
    unittest.main()
