# spotter: a profile-driven intel engine

One engine, one YAML profile per recipient. The fleet ran several daily
digests off this engine for very different readers (a builder's radar, a
product-complaints watch, an industry news brief). The engine never hardcodes
a person. Everything that differs lives in the profile: beats, terms, sources,
thresholds, tone.

This is the deterministic half. It fetches, ranks, and writes a facts file.
The model half (writing the message) and delivery live in
[`../headless-runner`](../headless-runner).

```
fetch (free sources, each fails independently)
  -> route into a beat   co-occurrence groups first, then term lists (word-boundary)
  -> score               0.55 relevance + 0.30 engagement + 0.15 recency
                         + 0.25 * negativity on `lean: negative` beats
                         x source-trust multiplier
  -> filter              seen-state, maxAgeDays, minRelevance, minNegativity
  -> diversify           no beat takes more than ~60% of slots
  -> write               <slug>-ranked.json + <slug>-facts.md   (exit 3 = quiet day)
```

## Design decisions

**Word-boundary matching everywhere.** An early profile routed on the term
`ai`, which matched "hair", "nails", and "said". Terms now match on word
boundaries, using lookarounds so `c++` and `.net` still work.

**Co-occurrence beats.** A flat term list can't express "this product AND a
failure word." A beat can declare `coOccur: [[products...], [failure words...]]`,
and it matches only when every group has a hit. Co-occurrence beats are
checked first, in declaration order. Term beats are checked after, and the one
with the most distinct hits wins. Ties go to the earlier beat, so YAML order is
priority order.

**Negativity lean, with star ratings.** Some digests exist to catch complaints.
A `lean: negative` beat adds lexicon-based negativity to the score. For app
reviews, `starsAsSentiment: true` lets the rating override the wording: 1–2
stars is fully negative, 3 is partial, and 4–5 is not negative at all, because
"I hate how much I love this" is a five-star review.

**Recency ranks; it doesn't gate.** Freshness started out as a filter. On slow
days that meant strong, relevant items just outside the window never appeared. Recency now decays linearly over `freshWindowHours` as one
term in the score. The hard cut is `maxAgeDays`, and seen-state dedup does the
anti-repeat job the recency gate was being misused for.

**Dedup on canonical identity.** Seen-state stores a hash of the item's URL. One
source put per-fetch tracking tokens in its share URLs, so the same item hashed
differently every day and showed up again in consecutive digests. `item_id`
strips tracking params. If you add a source, canonicalize its URLs there.

**The engine never mutates seen-state.** `commit_seen.py` does, and the runner
calls it only after a confirmed send.

**Outcome-learned source trust.** Each surfaced item's source is logged. When
the human acts on an item (in the original: replying "build 1"), or ignores or
tosses it, that outcome is logged too. `update_trust.py` recomputes a
per-source multiplier, `0.85 + 0.6 * acted_rate` clamped to `[0.7, 1.3]`, once a
source has at least 3 outcomes. It's deterministic and explainable, and it stays
bounded so one lucky source can't take over the digest. Replies are tuning
data only. They adjust weights, and they can never add a recipient or trigger
a send.

## Sources

Shipped: Hacker News (Algolia API), App Store reviews (public iTunes RSS),
RSS/Atom (stdlib parser), and GitHub new-repo search. All are free and need no
key. The original also used paid social-video and forum search through a
scraping API, plus YouTube via `yt-dlp`. Those are left out. To add a source,
return `dict(source, url, text, created_ts, eng)` items and append the function
to `FETCHERS`.

## Run it

```sh
pip install pyyaml
python3 engine/build_digest.py profiles/ai-dev-tooling.yaml ./scratch ./state/seen.json
python3 -m unittest discover -s tests       # 18 offline tests
```

`profiles/ai-dev-tooling.yaml` is the only profile shipped, and it's a neutral
example. Real profiles, seen-state, trust files, and outcome logs are not
included.
