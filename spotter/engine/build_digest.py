#!/usr/bin/env python3
"""
build_digest.py — the deterministic half of a profile-driven intel engine.

One engine, one YAML profile per recipient. For a profile it:
  1. fetches candidates from free sources (HN Algolia, App Store reviews,
     RSS/Atom, GitHub new-repo search); each source fails independently
  2. routes each item into a weighted beat (co-occurrence groups first, then
     term lists; word-boundary matching throughout)
  3. scores relevance + engagement + recency (+ negativity on `lean: negative`
     beats), times an outcome-learned per-source trust multiplier
  4. drops anything already in seen-state, caps any one beat at ~60% of slots
  5. writes <scratch>/<slug>-ranked.json (structured facts) and
     <scratch>/<slug>-facts.md (the ONLY thing the LLM step gets to read)

It never writes prose, never sends, and never mutates seen-state. The runner
commits seen IDs only after a successful send (see commit_seen.py), so a failed
send doesn't hide items from tomorrow's run.

Usage:  build_digest.py <profile.yaml> <scratch_dir> <seen.json>
Exit:   0 = >=1 item written · 3 = nothing cleared the floor (quiet day) · 1 = fatal
Deps:   PyYAML (profile parsing). Everything else is stdlib.
"""
import hashlib
import html
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

UA = "Mozilla/5.0 (intel-spotter/1.0)"

# Generic negative-sentiment cues. Profiles extend this with `negLex`.
NEG_LEX = ["broken", "crash", "crashes", "bug", "buggy", "regression", "outage",
           "unusable", "doesn't work", "does not work", "stopped working", "slow",
           "disappointed", "refund", "overhyped", "overpriced", "not worth", "waste",
           "hate", "worst", "terrible", "awful", "regret", "frustrating", "deprecated"]


# ---------------------------------------------------------------- helpers
def norm(s):
    return re.sub(r"\s+", " ", (s or "").lower()).strip()


def item_id(url, text):
    """Stable identity for seen-state. Hash the canonical URL; if a source puts
    per-fetch tracking tokens in its URLs, canonicalize here first or the same
    item hashes differently every day and dedup silently fails."""
    u = (url or "").strip()
    if u.startswith("http"):
        p = urllib.parse.urlsplit(u)
        q = urllib.parse.parse_qsl(p.query, keep_blank_values=True)
        q = [(k, v) for k, v in q if not k.lower().startswith("utm_")]
        u = urllib.parse.urlunsplit((p.scheme, p.netloc.lower(), p.path,
                                     urllib.parse.urlencode(q), ""))
    return hashlib.sha1((u or text or "")[:400].encode("utf-8", "ignore")).hexdigest()[:16]


def match_terms(text, terms):
    """Word-boundary matching: 'ai' must not match 'hair' or 'said'. Lookarounds
    instead of \\b so terms like 'c++' or '.net' still work."""
    t = norm(text)
    hits = []
    for x in terms:
        pat = r"(?<!\w)" + re.escape(norm(x)) + r"(?!\w)"
        if re.search(pat, t):
            hits.append(x)
    return hits


def http_get_json(url, params=None, timeout=30):
    if params:
        url = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def http_get_bytes(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def log(msg):
    print(msg, file=sys.stderr)


# ---------------------------------------------------------------- sources
# Each fetcher returns list[dict(source, url, text, created_ts, eng)] and never
# raises; a failing source logs and returns what it has.
#
# Paid sources (social-video search, Reddit via a scraping API) ran in the
# original fleet and are deliberately not shipped. To add one, return items in
# the same shape and add it to FETCHERS.

def fetch_hackernews(prof, now):
    cfg = prof.get("sources", {}).get("hackernews") or {}
    out = []
    if not cfg:
        return out
    since = int(now - cfg.get("windowDays", 4) * 86400)
    minpts = cfg.get("minPoints", 0)

    def emit(hits):
        kept = 0
        for h in hits:
            pts = int(h.get("points") or 0)
            if pts < minpts:
                continue
            title = h.get("title") or h.get("story_title") or ""
            snippet = html.unescape(re.sub("<[^>]+>", "", h.get("story_text") or ""))[:400]
            oid = h.get("objectID") or ""
            url = h.get("url") or (f"https://news.ycombinator.com/item?id={oid}" if oid else "")
            text = (title + (" — " + snippet if snippet else "")).strip(" —")
            if text:
                out.append(dict(source="Hacker News", url=url, text=text,
                                created_ts=float(h.get("created_at_i") or 0),
                                eng=dict(points=pts, comments=int(h.get("num_comments") or 0))))
                kept += 1
        return kept

    for q in cfg.get("queries", []):
        try:
            hits = http_get_json("https://hn.algolia.com/api/v1/search_by_date",
                                 {"query": q, "tags": "story",
                                  "numericFilters": f"created_at_i>{since}",
                                  "hitsPerPage": cfg.get("hitsPerPage", 40)}).get("hits") or []
            log(f"  hackernews '{q}': {len(hits)} raw / {emit(hits)} kept")
        except Exception as e:
            log(f"  hackernews '{q}' FAILED: {e}")
    if cfg.get("frontPage"):
        try:
            hits = http_get_json("https://hn.algolia.com/api/v1/search",
                                 {"tags": "front_page",
                                  "hitsPerPage": cfg.get("hitsPerPage", 40)}).get("hits") or []
            log(f"  hackernews front_page: {len(hits)} raw / {emit(hits)} kept")
        except Exception as e:
            log(f"  hackernews front_page FAILED: {e}")
    return out


def fetch_appstore(prof, now):
    """Public iTunes customer-review RSS (no key). The app name and star rating
    are embedded in the text so co-occurrence routing and starsAsSentiment work
    even when the review body never names the app."""
    cfg = prof.get("sources", {}).get("appstore") or {}
    out = []
    for app in cfg.get("apps", []):
        app_id, name = str(app["id"]), app.get("name", "app")
        n0 = len(out)
        for page in range(1, cfg.get("pages", 3) + 1):
            try:
                d = http_get_json(f"https://itunes.apple.com/rss/customerreviews/"
                                  f"page={page}/id={app_id}/sortby=mostrecent/json")
                entries = d.get("feed", {}).get("entry", [])
                if isinstance(entries, dict):
                    entries = [entries]
                for e in entries:
                    title = e.get("title", {}).get("label", "")
                    body = e.get("content", {}).get("label", "")
                    stars = e.get("im:rating", {}).get("label", "?")
                    rid = e.get("id", {}).get("label", "") or f"{app_id}-{title[:40]}"
                    ts = 0.0
                    upd = e.get("updated", {}).get("label", "")
                    if upd:
                        try:
                            ts = datetime.fromisoformat(upd).timestamp()
                        except ValueError:
                            pass
                    out.append(dict(source=f"App Store: {name}", url=rid,
                                    text=f"{name} app review [{stars}/5 stars]: {title} — {body[:500]}",
                                    created_ts=ts, eng={}))
            except Exception as ex:
                log(f"  appstore {name} p{page} FAILED: {ex}")
                break
        log(f"  appstore {name}: {len(out) - n0} reviews")
    return out


def _parse_feed(raw):
    """Minimal RSS 2.0 / Atom parser (stdlib). Returns (feed_title, entries)."""
    root = ET.fromstring(raw)
    atom = "{http://www.w3.org/2005/Atom}"
    entries = []
    if root.tag == atom + "feed":
        title = (root.findtext(atom + "title") or "").strip()
        for e in root.findall(atom + "entry"):
            link = ""
            for ln in e.findall(atom + "link"):
                if ln.get("rel", "alternate") == "alternate":
                    link = ln.get("href", ""); break
            entries.append(dict(title=e.findtext(atom + "title") or "", link=link,
                                summary=e.findtext(atom + "summary") or e.findtext(atom + "content") or "",
                                date=e.findtext(atom + "published") or e.findtext(atom + "updated") or ""))
    else:
        ch = root.find("channel")
        ch = ch if ch is not None else root
        title = (ch.findtext("title") or "").strip()
        for e in ch.findall("item"):
            entries.append(dict(title=e.findtext("title") or "", link=e.findtext("link") or "",
                                summary=e.findtext("description") or "",
                                date=e.findtext("pubDate") or ""))
    return title, entries


def _parse_date(s):
    s = (s or "").strip()
    if not s:
        return 0.0
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        pass
    try:
        from email.utils import parsedate_to_datetime
        return parsedate_to_datetime(s).timestamp()
    except (TypeError, ValueError):
        return 0.0


def fetch_rss(prof, now):
    out = []
    for feed in prof.get("sources", {}).get("rss") or []:
        try:
            title, entries = _parse_feed(http_get_bytes(feed))
            log(f"  rss {title or feed}: {len(entries)} entries")
            for e in entries[:25]:
                summ = html.unescape(re.sub("<[^>]+>", "", e["summary"]))[:500]
                out.append(dict(source=f"RSS: {title or feed}", url=e["link"],
                                text=(e["title"] + " — " + summ).strip(" —"),
                                created_ts=_parse_date(e["date"]), eng={}))
        except Exception as e:
            log(f"  rss {feed} FAILED: {e}")
    return out


def fetch_github(prof, now):
    """Unauthenticated GitHub search (10 req/min): new repos sorted by stars,
    i.e. what builders are shipping now, not the all-time giants."""
    cfg = prof.get("sources", {}).get("github") or {}
    out = []
    if not cfg:
        return out
    since = datetime.fromtimestamp(now - cfg.get("createdDays", 14) * 86400,
                                   tz=timezone.utc).strftime("%Y-%m-%d")
    for q in cfg.get("queries", []):
        try:
            items = http_get_json("https://api.github.com/search/repositories",
                                  {"q": f"{q} created:>{since} stars:>={cfg.get('minStars', 20)}",
                                   "sort": "stars", "order": "desc",
                                   "per_page": cfg.get("perPage", 15)}).get("items") or []
            for repo in items:
                ts = _parse_date(repo.get("created_at", ""))
                topics = " ".join(repo.get("topics") or [])
                out.append(dict(source="GitHub", url=repo.get("html_url", ""),
                                text=f"{repo.get('full_name', '')} — {repo.get('description') or ''}"
                                     + (f" [{topics}]" if topics else ""),
                                created_ts=ts,
                                eng=dict(stars=int(repo.get("stargazers_count") or 0))))
            log(f"  github '{q}': {len(items)} raw")
            time.sleep(2)
        except Exception as e:
            log(f"  github '{q}' FAILED: {e}")
    return out


FETCHERS = [fetch_hackernews, fetch_rss, fetch_appstore, fetch_github]


# ---------------------------------------------------------------- classify
def classify(item, prof):
    """Return (beat, matches). Co-occurrence beats are checked first, in
    declaration order: `coOccur: [groupA, groupB]` matches only when EVERY
    group has a hit, which expresses "product AND (bug|outage)" in a way a
    flat term list can't. Then term beats: most distinct hits wins, and ties
    go to the earlier-declared beat, so order beats by priority in the YAML."""
    text = item["text"] + " " + item.get("author", "")
    beats = prof["beats"]
    for beat, cfg in beats.items():
        groups = cfg.get("coOccur")
        if groups:
            ghits = [match_terms(text, g) for g in groups]
            if all(ghits):
                return beat, sorted(set(sum(ghits, [])))
    best_beat, best_hits = None, []
    for beat, cfg in beats.items():
        if cfg.get("terms"):
            hits = match_terms(text, cfg["terms"])
            if len(hits) > len(best_hits):
                best_beat, best_hits = beat, hits
    return (best_beat, sorted(set(best_hits))) if best_beat else (None, [])


def _log10(x):
    return math.log10(x) if x > 0 else 0


def virality(item):
    """Engagement in [0,1], log-scaled per source so the numbers are comparable."""
    e = item.get("eng") or {}
    if "points" in e:          # HN: ~2000 points+comments ~= 1.0
        return min(1.0, _log10(e["points"] + 2 * e.get("comments", 0)) / 3.3)
    if "stars" in e:           # GitHub stars on a NEW repo: ~1000 ~= 1.0
        return min(1.0, _log10(e["stars"]) / 3.0)
    if "score" in e:           # forum-style score: ~10^4 ~= 1.0
        return min(1.0, _log10(e["score"] + 3 * e.get("comments", 0)) / 4.0)
    return 0.35                # RSS / reviews carry no engagement: mid prior


STARS_RE = re.compile(r"\[(\d)/5 stars\]")


def negativity(text, prof=None):
    """Lexicon hits -> [0,1]. With `starsAsSentiment`, an app-review star rating
    overrides the words: 1-2 stars = fully negative, 3 = partial, 4-5 = not
    negative regardless of wording ("I hate how much I love this")."""
    prof = prof or {}
    t = norm(text)
    hits = [w for w in NEG_LEX + list(prof.get("negLex") or []) if w in t]
    neg = min(1.0, len(hits) / 3.0)
    if prof.get("starsAsSentiment"):
        m = STARS_RE.search(text or "")
        if m:
            stars = int(m.group(1))
            if stars <= 2:
                neg, hits = 1.0, hits + [f"{stars}-star review"]
            elif stars == 3:
                neg, hits = max(neg, 0.5), hits + ["3-star review"]
            else:
                neg = 0.0
    return neg, hits


def score(item, prof, now):
    beat, hits = classify(item, prof)
    if not beat:
        return None
    bcfg = prof["beats"][beat]
    vir = virality(item)
    neg, neghits = negativity(item["text"], prof)
    lean_boost = 0.25 * neg if bcfg.get("lean") == "negative" else 0.0
    # Recency is a RANKING signal, not a gate: it decays linearly over
    # freshWindowHours, and older items stay eligible if relevance/engagement
    # carry them. The hard staleness cut is maxAgeDays (in rank()). Unknown
    # timestamp => neutral-low.
    fresh_w = max(prof.get("freshWindowHours", 96), 1)
    if item.get("created_ts"):
        age_h = (now - item["created_ts"]) / 3600
        rec = max(0.0, 1 - age_h / fresh_w)
    else:
        age_h, rec = -1, 0.3
    relevance = min(1.0, (0.45 + 0.20 * len(hits)) * bcfg.get("weight", 1.0))
    final = 0.55 * relevance + 0.30 * vir + 0.15 * rec + lean_boost
    # Outcome-learned source trust (update_trust.py): sources whose items the
    # human acted on rank up, ignored ones rank down. Prefix match, so a key of
    # "RSS" covers every feed.
    for src, mult in (prof.get("_sourceTrust") or {}).items():
        if item["source"].lower().startswith(src.lower()):
            final *= float(mult)
            break
    item.update(beat=beat, matches=hits, virality=round(vir, 3),
                negativity=round(neg, 3), neg_hits=neghits,
                age_hours=round(age_h, 1), relevance=round(relevance, 3),
                score=round(final, 4))
    return item


def rank(cands, prof, seen, now):
    """Pure: candidates -> (picked, full above-floor pool)."""
    max_age_s = prof.get("maxAgeDays", 21) * 86400
    sig = prof.get("signal", {})
    best = {}
    for it in cands:
        it["id"] = item_id(it.get("url"), it.get("text"))
        if it["id"] in seen:
            continue
        if it.get("created_ts") and (now - it["created_ts"]) > max_age_s:
            continue
        s = score(it, prof, now)
        if not s or s["score"] < sig.get("minRelevance", 0.5) \
                or s["negativity"] < sig.get("minNegativity", 0):
            continue
        if s["id"] not in best or s["score"] > best[s["id"]]["score"]:
            best[s["id"]] = s
    pool = sorted(best.values(), key=lambda x: -x["score"])

    # Beat diversity: no beat takes more than ~60% of slots; backfill if the
    # cap leaves slots empty.
    maxn = prof.get("maxItems", 8)
    cap = max(1, round(maxn * 0.6))
    picked, per = [], {}
    for it in pool:
        if per.get(it["beat"], 0) >= cap:
            continue
        picked.append(it)
        per[it["beat"]] = per.get(it["beat"], 0) + 1
        if len(picked) >= maxn:
            break
    for it in pool:
        if len(picked) >= maxn:
            break
        if it not in picked:
            picked.append(it)
    picked.sort(key=lambda x: -x["score"])
    return picked, pool


def load_trust(prof, prof_path):
    if not prof.get("sourceTrust"):
        return {}
    tp = prof["sourceTrust"]
    if not os.path.isabs(tp):
        tp = os.path.join(os.path.dirname(os.path.abspath(prof_path)), tp)
    try:
        with open(tp) as f:
            return json.load(f).get("sources", {})
    except Exception as e:
        log(f"source-trust unavailable ({e}); neutral")
        return {}


def write_outputs(prof, picked, pool, scratch):
    slug = re.sub(r"[^a-z0-9]+", "-", norm(prof["name"])).strip("-")
    os.makedirs(scratch, exist_ok=True)
    gen = datetime.now(timezone.utc).isoformat()
    rj = os.path.join(scratch, f"{slug}-ranked.json")
    with open(rj, "w") as f:
        json.dump(dict(profile=prof["name"], generated=gen, items=picked), f, indent=2)
    with open(os.path.join(scratch, f"{slug}-pool.json"), "w") as f:
        json.dump(dict(profile=prof["name"], generated=gen, items=pool), f, indent=2)
    with open(os.path.join(scratch, f"{slug}-facts.md"), "w") as f:
        f.write(f"# {prof.get('title', prof['name'])}: verified facts ({len(picked)} items)\n\n")
        for i, it in enumerate(picked, 1):
            f.write(f"## {i}. [{it['beat']}] {it['source']}\n")
            f.write(f"- score {it['score']} (rel {it['relevance']} · engagement {it['virality']}"
                    f" · neg {it['negativity']} · {it['age_hours']}h old)\n")
            f.write(f"- matches: {', '.join(it['matches']) or '-'}")
            if it.get("neg_hits"):
                f.write(f" | negative cues: {', '.join(it['neg_hits'])}")
            f.write("\n")
            if it.get("eng"):
                f.write(f"- engagement: {json.dumps(it['eng'])}\n")
            f.write(f"- url: {it['url']}\n- text: {it['text'][:400]}\n\n")
    return rj


def main(argv=None, fetchers=None, now=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    try:
        import yaml
    except ImportError:
        log("FATAL: PyYAML required (pip install pyyaml)")
        return 1
    prof_path, scratch, seen_path = argv
    now = time.time() if now is None else now
    with open(prof_path) as f:
        prof = yaml.safe_load(f)
    prof["_sourceTrust"] = load_trust(prof, prof_path)
    seen = set()
    if os.path.exists(seen_path):
        with open(seen_path) as f:
            seen = set(json.load(f).get("ids", []))

    cands = []
    for fn in (FETCHERS if fetchers is None else fetchers):
        try:
            cands += fn(prof, now)
        except Exception as e:
            log(f"  source {fn.__name__} crashed: {e}")
    log(f"fetched {len(cands)} raw candidates")

    picked, pool = rank(cands, prof, seen, now)
    rj = write_outputs(prof, picked, pool, scratch)
    log(f"wrote {len(picked)} items -> {rj}")
    print(rj)
    return 0 if picked else 3


if __name__ == "__main__":
    sys.exit(main())
