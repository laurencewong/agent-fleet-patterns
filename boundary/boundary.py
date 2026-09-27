#!/usr/bin/env python3
"""boundary.py — the single python entry point for the fleet boundary store.

Stdlib only. The bash hook (examples/escalate.sh + hooklib.sh) stays the
enforcer; this program is a stateless helper over the store at $FLEET_BOUNDARY:

  init                      create/upgrade the store (idempotent)
  redact    --agent A       stdin text/JSON -> redacted (never leaks; <=2KB)
  hash      --agent A       stdin hook JSON -> canonical call_hash (v1 scheme)
  classify  --agent A --tool T   -> "RISKCLASS\ttarget_arg"
  audit     --agent A --decision D --rule R [--zone Z]   (ALWAYS exit 0)
  enqueue   --agent A --tripwire W --reason R [--stub P] (ALWAYS exit 0)
  gate      --agent A --tool T --tripwire W   exit 0 + rule name iff a grant
                                              covers the call; else exit != 0
  reconcile --agent A       print pending/approved reminders (ALWAYS exit 0)
  inbox     list|show|resolve|gc
  grants    list|check --agent A

FAIL-TOWARD-BLOCKING: gate fails => non-zero => the
hook's deny stands. audit/enqueue/reconcile fail => flat fallback log / silent
=> exit 0 so they can never stall or crash a tool call. No path here can turn
a deny into an allow except a valid grant.
"""

import json
import hashlib
import os
import re
import sqlite3
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone

PROC_START = time.monotonic()

HASH_VERSION = "v1"
REDACT_CAP = 2048
BODY_KEEP = 48
PENDING_CAP = 50
ONESHOT_TTL_DAYS = 7
STANDING_TTL_MAX_DAYS = 92
MASK = "•••"

# Tripwires that can NEVER be granted past (the enforcer protects itself and
# the spend cap; hard-coded, not config).
NEVER_GRANT_SUBSTRINGS = ("self-config", "spend")
# Tools that can NEVER get a STANDING rule (shell / local write).
NEVER_STANDING_TOOLS = {"Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "Update"}
# A standing grant fires only on outward-shaped tripwires.
OUTWARD_SUBSTRINGS = ("outward", "relational")
# The one human who may ratify standing grants and mint one-shots. Hard-coded
# ON PURPOSE: an environment variable or a flag default would be settable by
# the very agent being gated. "<owner>-phone" is the pager reply surface
# (the human texting "allow 107"), mapped to the owner for explicit approves.
OWNER = "owner"
MINTERS = {OWNER, OWNER + "-phone"}

KEY_RE = re.compile(r"(?i)(token|secret|passw|api_?key|authorization|bearer|cookie|credential)")
BODY_RE = re.compile(r"(?i)^(text|body|content|message|caption)$")
BODY_DONE_RE = re.compile(r"…\[\+\d+ chars\]$")
TRUNC_MARK = "…[truncated]"
LITERAL_RES = [
    re.compile(r"sk-[A-Za-z0-9_-]{10,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{10,}"),
    re.compile(r"xox[a-z]-[A-Za-z0-9-]{8,}"),
    re.compile(r"AKIA[A-Z0-9]{12,}"),
    re.compile(r"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}"),
    re.compile(r"-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----"),
]
FLAG_RE = re.compile(r"(?i)(--(?:token|password|passwd|api[-_]?key|apikey|secret|auth(?:orization)?)[= ])\S+")
AUTH_HDR_RE = re.compile(r"(?i)(-H\s+[\"']?Authorization:\s*)[^\"']+")
VAR_RE = re.compile(r"(?i)\b([A-Za-z_]*(?:TOKEN|SECRET|PASSW[A-Za-z]*|API_?KEY|APIKEY)[A-Za-z_]*)=(\S+)")


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def store_dir(args):
    d = getattr(args, "store", None) or os.environ.get("FLEET_BOUNDARY", "")
    if not d:
        raise RuntimeError("no store: set FLEET_BOUNDARY or pass --store")
    return os.path.realpath(d)


def db_path(args):
    return os.path.join(store_dir(args), "boundary.db")


def connect(args):
    con = sqlite3.connect(db_path(args), timeout=2.0)
    con.execute("PRAGMA busy_timeout=2000")
    return con


def elapsed_ms():
    return int((time.monotonic() - PROC_START) * 1000)


# ---------------------------------------------------------------- redaction
def _scrub_str(s):
    for rx in LITERAL_RES:
        s = rx.sub(MASK, s)
    s = FLAG_RE.sub(lambda m: m.group(1) + MASK, s)
    s = AUTH_HDR_RE.sub(lambda m: m.group(1) + MASK, s)
    s = VAR_RE.sub(lambda m: m.group(1) + "=" + MASK, s)
    return s


def _redact_value(key, val):
    if isinstance(val, dict):
        return {k: _redact_value(k, v) for k, v in val.items()}
    if isinstance(val, list):
        return [_redact_value(key, v) for v in val]
    if not isinstance(val, str):
        return val
    if key is not None and KEY_RE.search(key):
        return MASK
    if key is not None and BODY_RE.match(key):
        if BODY_DONE_RE.search(val):
            return _scrub_str(val)
        v = _scrub_str(val)
        if len(v) > BODY_KEEP:
            return v[:BODY_KEEP] + "…[+%d chars]" % (len(v) - BODY_KEEP)
        return v
    return _scrub_str(val)


def redact_text(raw):
    raw = raw if isinstance(raw, str) else raw.decode("utf-8", "replace")
    out = None
    try:
        obj = json.loads(raw)
        if isinstance(obj, (dict, list)):
            out = json.dumps(_redact_value(None, obj), ensure_ascii=False)
    except (ValueError, TypeError):
        pass
    if out is None:
        out = _scrub_str(raw)
    if len(out) > REDACT_CAP:
        out = out[: REDACT_CAP - len(TRUNC_MARK)] + TRUNC_MARK
    return out


# ---------------------------------------------------------------- hashing
def call_hash(agent, tool_name, tool_input):
    canonical = json.dumps(tool_input or {}, sort_keys=True,
                           separators=(",", ":"), ensure_ascii=False)
    payload = "%s\n%s\n%s\n%s" % (HASH_VERSION, agent, tool_name, canonical)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- riskclass
def _load_tsv(path):
    rows = {}
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            tool = parts[0].strip()
            rc = parts[1].strip()
            ta = parts[2].strip() if len(parts) > 2 and parts[2].strip() else "-"
            rows[tool] = (rc, ta)
    return rows


def classify_tool(store, agent, tool):
    table = _load_tsv(os.path.join(store, "riskclass.tsv"))
    table.update(_load_tsv(os.path.join(store, "riskclass.d", "%s.tsv" % agent)))
    if tool in table:
        return table[tool]
    if tool.startswith("mcp__"):
        return table.get("mcp__*", ("EXTERNAL", "-"))
    return table.get("*", ("READ", "-"))


# ---------------------------------------------------------------- helpers
def read_hook_input():
    raw = sys.stdin.read()
    try:
        obj = json.loads(raw)
        if not isinstance(obj, dict):
            obj = {}
    except (ValueError, TypeError):
        obj = {}
    return raw, obj


def extract_resource(store, agent, tool, tool_input):
    _, target_arg = classify_tool(store, agent, tool)
    if target_arg != "-" and isinstance(tool_input, dict):
        v = tool_input.get(target_arg)
        if isinstance(v, str) and v:
            return v
    if tool == "Bash" and isinstance(tool_input, dict):
        m = re.search(r"https?://\S+", str(tool_input.get("command", "")))
        if m:
            return m.group(0)
    return None


def fallback_log(args, line):
    try:
        p = os.path.join(store_dir(args), "audit-fallback.log")
        with open(p, "a", encoding="utf-8") as f:
            f.write(line.rstrip("\n") + "\n")
    except Exception:
        pass


def audit_row(args, con, agent, tool, decision, rule, *, zone=None, riskclass=None,
              resource=None, redacted=None, chash=None, session_id=None):
    con.execute(
        "INSERT INTO audit_events(ts, agent, session_id, automation_id, tool_name,"
        " riskclass, zone, decision, rule, resource, redacted_input, call_hash, hook_ms)"
        " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (utcnow(), agent, session_id, os.environ.get("AUTOMATION_ID"), tool,
         riskclass, zone or "n/a", decision, rule, resource, redacted, chash,
         elapsed_ms()))


# ---------------------------------------------------------------- subcommands
def cmd_init(args):
    store = store_dir(args)
    os.makedirs(store, exist_ok=True)
    os.makedirs(os.path.join(store, "riskclass.d"), exist_ok=True)
    os.makedirs(os.path.join(store, "grants.d"), exist_ok=True)
    here = os.path.dirname(os.path.realpath(__file__))
    schema = os.path.join(store, "schema.sql")
    if not os.path.isfile(schema):
        schema = os.path.join(here, "schema.sql")
    with open(schema, encoding="utf-8") as f:
        ddl = f.read()
    con = connect(args)
    try:
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript(ddl)
        con.commit()
    finally:
        con.close()
    print("store initialized: %s" % store)
    return 0


def cmd_redact(args):
    print(redact_text(sys.stdin.read()), end="")
    return 0


def cmd_hash(args):
    _, obj = read_hook_input()
    print(call_hash(args.agent, obj.get("tool_name", ""), obj.get("tool_input", {})))
    return 0


def cmd_classify(args):
    rc, ta = classify_tool(store_dir(args), args.agent, args.tool)
    print("%s\t%s" % (rc, ta))
    return 0


def cmd_audit(args):
    try:
        raw, obj = read_hook_input()
        store = store_dir(args)
        tool = obj.get("tool_name", "") or "?"
        ti = obj.get("tool_input", {})
        rc, _ = classify_tool(store, args.agent, tool)
        con = connect(args)
        try:
            audit_row(args, con, args.agent, tool, args.decision, args.rule,
                      zone=args.zone, riskclass=rc,
                      resource=extract_resource(store, args.agent, tool, ti),
                      redacted=redact_text(raw), chash=call_hash(args.agent, tool, ti),
                      session_id=obj.get("session_id"))
            con.commit()
        finally:
            con.close()
    except Exception as e:
        try:
            fallback_log(args, "%s agent=%s decision=%s rule=%s err=%s" %
                         (utcnow(), args.agent, args.decision, args.rule, e))
        except Exception:
            pass
    return 0  # NEVER blocks a tool call


def cmd_enqueue(args):
    try:
        raw, obj = read_hook_input()
        store = store_dir(args)
        tool = obj.get("tool_name", "") or "?"
        ti = obj.get("tool_input", {})
        rc, _ = classify_tool(store, args.agent, tool)
        chash = call_hash(args.agent, tool, ti)
        now = utcnow()
        con = connect(args)
        try:
            cur = con.execute(
                "SELECT count(*) FROM inbox_items WHERE agent=? AND status='pending'",
                (args.agent,))
            pending = cur.fetchone()[0]
            cur = con.execute(
                "SELECT count(*) FROM inbox_items WHERE agent=? AND call_hash=?"
                " AND status='pending'", (args.agent, chash))
            existing = cur.fetchone()[0]
            if pending >= PENDING_CAP and not existing:
                # flood guard (R6): deny already stands; skip enqueue, audit it.
                audit_row(args, con, args.agent, tool, "enqueue_capped",
                          args.tripwire, chash=chash)
                con.commit()
                return 0
            con.execute(
                "INSERT INTO inbox_items(created_at, agent, session_id, automation_id,"
                " tool_name, riskclass, tripwire, reason, resource, call_hash,"
                " redacted_input, stub_path, last_seen_at)"
                " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)"
                " ON CONFLICT(agent, call_hash) WHERE status='pending'"
                " DO UPDATE SET seen_count=seen_count+1, last_seen_at=excluded.last_seen_at",
                (now, args.agent, obj.get("session_id"), os.environ.get("AUTOMATION_ID"),
                 tool, rc, args.tripwire, args.reason,
                 extract_resource(store, args.agent, tool, ti), chash,
                 redact_text(raw), args.stub, now))
            con.commit()
        finally:
            con.close()
    except Exception as e:
        try:
            fallback_log(args, "%s agent=%s ENQUEUE-FAIL tripwire=%s err=%s" %
                         (utcnow(), args.agent, args.tripwire, e))
        except Exception:
            pass
    return 0  # deny already stands; enqueue failure must not crash the hook


def _touches_store(store, tool_input):
    """Forgery guard: no grant may cover a call whose inputs point into the
    store itself (an agent must never be grantable INTO the boundary store)."""
    def walk(v):
        if isinstance(v, dict):
            return any(walk(x) for x in v.values())
        if isinstance(v, list):
            return any(walk(x) for x in v)
        if isinstance(v, str):
            s = os.path.expanduser(v) if v.startswith("~") else v
            if os.path.isabs(s):
                rp = os.path.realpath(s)
                if rp == store or rp.startswith(store + os.sep):
                    return True
            return store in v
        return False
    return walk(tool_input)


def cmd_gate(args):
    # ANY failure => non-zero => the hook's deny stands (fail-toward-blocking).
    _, obj = read_hook_input()
    store = store_dir(args)
    tool = args.tool or obj.get("tool_name", "")
    ti = obj.get("tool_input", {})
    trip = (args.tripwire or "").lower()
    if any(s in trip for s in NEVER_GRANT_SUBSTRINGS):
        return 1
    if _touches_store(store, ti):
        return 1
    chash = call_hash(args.agent, tool, ti)
    now = utcnow()
    con = connect(args)
    try:
        con.execute("BEGIN IMMEDIATE")
        cur = con.execute(
            "SELECT id, minted_from, minted_by, expires_at FROM oneshot_grants"
            " WHERE agent=? AND call_hash=? AND consumed_at IS NULL",
            (args.agent, chash))
        row = cur.fetchone()
        if row is not None:
            gid, minted_from, minted_by, expires_at = row
            if minted_by not in MINTERS or expires_at <= now:
                audit_row(args, con, args.agent, tool, "grant_invalid",
                          "oneshot:%d:%s" % (gid, "expired" if expires_at <= now
                                             else "bad-minter"), chash=chash)
                con.commit()
            else:
                cur = con.execute(
                    "UPDATE oneshot_grants SET consumed_at=? WHERE id=?"
                    " AND consumed_at IS NULL", (now, gid))
                if cur.rowcount == 1:
                    con.execute("UPDATE inbox_items SET consumed_at=? WHERE id=?",
                                (now, minted_from))
                    con.commit()
                    print("oneshot:%d" % gid)
                    return 0
                con.commit()  # lost the race: fall through to deny
        else:
            con.commit()
    finally:
        con.close()

    # ---- standing rules: cron-scoped, EXTERNAL-only, owner-ratified ----
    automation = os.environ.get("AUTOMATION_ID", "")
    if not automation:
        return 1
    if tool in NEVER_STANDING_TOOLS:
        return 1
    if not any(s in trip for s in OUTWARD_SUBSTRINGS):
        return 1
    rc, target_arg = classify_tool(store, args.agent, tool)
    if rc != "EXTERNAL" or target_arg == "-":
        return 1
    tv = ti.get(target_arg) if isinstance(ti, dict) else None
    if not isinstance(tv, str) or not tv:
        return 1
    target_val = unicodedata.normalize("NFC", tv.strip())
    for g in load_grants(store, args.agent):
        why = grant_invalid_reason(store, args.agent, g)
        if why:
            con = connect(args)
            try:
                audit_row(args, con, args.agent, tool, "grant_invalid",
                          "standing:%s:%s" % (g["grant_id"], why), chash=chash)
                con.commit()
            finally:
                con.close()
            continue
        if (g["automation_id"] == automation and g["tool"] == tool
                and g["target_arg"] == target_arg
                and unicodedata.normalize("NFC", g["target_value"].strip()) == target_val):
            print("standing:%s" % g["grant_id"])
            return 0
    return 1


GRANT_FIELDS = ["grant_id", "automation_id", "tool", "target_arg", "target_value",
                "expires", "ratified_by", "ratified_on", "note"]


def load_grants(store, agent):
    path = os.path.join(store, "grants.d", "%s.tsv" % agent)
    out = []
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#") or line.startswith("grant_id"):
                continue
            parts = line.split("\t")
            g = {k: (parts[i].strip() if i < len(parts) else "")
                 for i, k in enumerate(GRANT_FIELDS)}
            out.append(g)
    return out


def grant_invalid_reason(store, agent, g):
    """A standing-grant row is honored only if EVERY check passes; else it is
    ignored + audited as grant_invalid, never partially honored."""
    if not g["grant_id"]:
        return "no-id"
    if not g["automation_id"] or g["automation_id"] == "-":
        return "no-automation-id"
    if g["ratified_by"] != OWNER:
        return "ratified-by-%s" % (g["ratified_by"] or "nobody")
    if g["tool"] in NEVER_STANDING_TOOLS:
        return "never-standing-tool"
    rc, ta = classify_tool(store, agent, g["tool"])
    if rc != "EXTERNAL":
        return "tool-not-external"
    if ta == "-" or g["target_arg"] != ta:
        return "target-arg-mismatch"
    if not g["target_value"]:
        return "no-target"
    if not g["expires"] or g["expires"][:10] < utcnow()[:10]:
        return "expired"
    return None


def cmd_reconcile(args):
    try:
        con = connect(args)
        try:
            cutoff = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime(
                "%Y-%m-%dT%H:%M:%SZ")
            cur = con.execute(
                "SELECT id, created_at, tripwire, reason, seen_count FROM inbox_items"
                " WHERE agent=? AND status='pending' AND created_at<=?"
                " ORDER BY id", (args.agent, cutoff))
            pend = cur.fetchall()
            cur = con.execute(
                "SELECT i.id, i.resolved_at, g.expires_at FROM inbox_items i"
                " JOIN oneshot_grants g ON g.minted_from=i.id"
                " WHERE i.agent=? AND i.status='resolved' AND i.resolution='allow_once'"
                " AND g.consumed_at IS NULL AND g.expires_at>? ORDER BY i.id",
                (args.agent, utcnow()))
            appr = cur.fetchall()
        finally:
            con.close()
        if pend:
            print("## boundary inbox: %d pending > 24h" % len(pend))
            for r in pend:
                print("- item #%d (%s, seen x%d) [%s] %s" % (r[0], r[1], r[4], r[2], r[3]))
        if appr:
            print("## boundary inbox: approved, awaiting retry")
            for r in appr:
                print("- item #%d APPROVED %s — one-shot grant, expires %s; retry the"
                      " exact call to consume" % (r[0], r[1], r[2]))
    except Exception:
        pass  # reconcile is prepended to runners; it must never break them
    return 0


def cmd_inbox(args):
    con = connect(args)
    try:
        if args.action == "list":
            cur = con.execute(
                "SELECT id, created_at, agent, tripwire, status, seen_count, reason"
                " FROM inbox_items WHERE status=? ORDER BY id", (args.status,))
            for r in cur.fetchall():
                print("#%d\t%s\t%s\t[%s]\tseen x%d\t%s" % (r[0], r[1], r[2], r[3], r[5], r[6]))
            return 0
        if args.action == "show":
            cur = con.execute("SELECT * FROM inbox_items WHERE id=?", (args.id,))
            row = cur.fetchone()
            if row is None:
                print("no item #%s" % args.id, file=sys.stderr)
                return 1
            cols = [d[0] for d in cur.description]
            for k, v in zip(cols, row):
                print("%s: %s" % (k, v))
            return 0
        if args.action == "resolve":
            res = args.resolution.replace("-", "_")
            if res not in ("allow_once", "deny", "noted", "rule_proposed"):
                print("bad resolution %s" % args.resolution, file=sys.stderr)
                return 2
            if res == "allow_once" and args.by not in MINTERS:
                print("refuse: only the owner (%s) can mint an allow-once"
                      " (got --by %s)" % (OWNER, args.by), file=sys.stderr)
                return 4
            now = utcnow()
            con.execute("BEGIN IMMEDIATE")
            cur = con.execute(
                "UPDATE inbox_items SET status='resolved', resolution=?,"
                " resolved_by=?, resolved_at=? WHERE id=? AND status='pending'",
                (res, args.by, now, args.id))
            if cur.rowcount != 1:
                cur = con.execute(
                    "SELECT status, resolution, resolved_by, resolved_at"
                    " FROM inbox_items WHERE id=?", (args.id,))
                row = cur.fetchone()
                con.commit()
                if row is None:
                    print("no item #%s" % args.id, file=sys.stderr)
                    return 2
                print("already resolved by %s at %s (%s)" % (row[2], row[3], row[1]))
                return 3
            if res == "allow_once":
                cur = con.execute(
                    "SELECT agent, call_hash FROM inbox_items WHERE id=?", (args.id,))
                agent, chash = cur.fetchone()
                expires = (datetime.now(timezone.utc)
                           + timedelta(days=ONESHOT_TTL_DAYS)).strftime(
                               "%Y-%m-%dT%H:%M:%SZ")
                con.execute(
                    "INSERT OR IGNORE INTO oneshot_grants(minted_from, agent,"
                    " call_hash, minted_by, minted_at, expires_at)"
                    " VALUES(?,?,?,?,?,?)",
                    (args.id, agent, chash, OWNER, now, expires))
                con.commit()
                print("resolved #%s allow_once by %s; one-shot minted, expires %s"
                      % (args.id, args.by, expires))
                return 0
            con.commit()
            print("resolved #%s %s by %s" % (args.id, res, args.by))
            return 0
        if args.action == "gc":
            cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).strftime(
                "%Y-%m-%dT%H:%M:%SZ")
            cur = con.execute(
                "UPDATE inbox_items SET status='expired' WHERE status='pending'"
                " AND created_at<=?", (cutoff,))
            con.commit()
            print("expired %d stale pending items" % cur.rowcount)
            return 0
        print("unknown inbox action", file=sys.stderr)
        return 2
    finally:
        con.close()


def cmd_grants(args):
    store = store_dir(args)
    gs = load_grants(store, args.agent)
    bad = 0
    for g in gs:
        why = grant_invalid_reason(store, args.agent, g)
        status = "INVALID(%s)" % why if why else "valid"
        if why:
            bad += 1
        print("%s\t%s\t%s\t%s=%s\texpires=%s\tratified_by=%s\t%s"
              % (g["grant_id"], g["automation_id"], g["tool"], g["target_arg"],
                 g["target_value"], g["expires"], g["ratified_by"], status))
    if args.action == "check":
        return 1 if bad else 0
    return 0


def main(argv):
    import argparse
    p = argparse.ArgumentParser(prog="boundary.py")
    p.add_argument("--store", default=None)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init")
    for name in ("redact", "hash"):
        s = sub.add_parser(name)
        s.add_argument("--agent", required=True)
    s = sub.add_parser("classify")
    s.add_argument("--agent", required=True)
    s.add_argument("--tool", required=True)
    s = sub.add_parser("audit")
    s.add_argument("--agent", required=True)
    s.add_argument("--decision", required=True)
    s.add_argument("--rule", required=True)
    s.add_argument("--zone", default=None)
    s = sub.add_parser("enqueue")
    s.add_argument("--agent", required=True)
    s.add_argument("--tripwire", required=True)
    s.add_argument("--reason", required=True)
    s.add_argument("--stub", default=None)
    s = sub.add_parser("gate")
    s.add_argument("--agent", required=True)
    s.add_argument("--tool", default=None)
    s.add_argument("--tripwire", required=True)
    s = sub.add_parser("reconcile")
    s.add_argument("--agent", required=True)
    s = sub.add_parser("inbox")
    s.add_argument("action", choices=["list", "show", "resolve", "gc"])
    s.add_argument("id", nargs="?", default=None)
    s.add_argument("resolution", nargs="?", default=None)
    s.add_argument("--by", default=None)
    s.add_argument("--status", default="pending")
    s = sub.add_parser("grants")
    s.add_argument("action", choices=["list", "check"])
    s.add_argument("--agent", required=True)

    args = p.parse_args(argv)
    fn = {"init": cmd_init, "redact": cmd_redact, "hash": cmd_hash,
          "classify": cmd_classify, "audit": cmd_audit, "enqueue": cmd_enqueue,
          "gate": cmd_gate, "reconcile": cmd_reconcile, "inbox": cmd_inbox,
          "grants": cmd_grants}[args.cmd]
    return fn(args)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as e:
        # Unhandled failure: print to stderr, exit 2. For gate this means "no
        # grant" (deny stands); audit/enqueue/reconcile catch internally.
        print("boundary.py: %s" % e, file=sys.stderr)
        sys.exit(2)
