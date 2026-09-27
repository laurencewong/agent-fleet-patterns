#!/usr/bin/env bash
# boundary.test.sh — unit/behavior suite for boundary.py + the ctl wrappers.
# Temp store per run; never touches a real store. Run: bash tests/boundary.test.sh
set -uo pipefail

REF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BPY="$REF/boundary.py"
STORE="$(mktemp -d)"
export FLEET_BOUNDARY="$STORE"
trap 'rm -rf "$STORE"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s%s\n' "$1" "${2:+ — $2}"; }
# eq <desc> <got> <want>
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }
# has <desc> <haystack> <needle> ; lacks <desc> <haystack> <needle>
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3'" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "leaked '$3'" ;; *) ok "$1" ;; esac; }

db() { sqlite3 "$STORE/boundary.db" "$@"; }
J() { jq -nc --arg t "$1" --argjson ti "$2" '{tool_name:$t, tool_input:$ti, session_id:"s-test"}'; }

echo "== T1: schema + init =="
python3 "$BPY" init >/dev/null 2>&1; st=$?
eq "init exits 0" "$st" "0"
eq "tables" "$(db "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name" | tr '\n' ' ')" "audit_events inbox_items oneshot_grants "
eq "WAL mode" "$(db "PRAGMA journal_mode")" "wal"
has "inbox partial unique index" "$(db "SELECT sql FROM sqlite_master WHERE name='inbox_pending_dedupe'")" "WHERE status = 'pending'"
has "oneshot partial unique index" "$(db "SELECT sql FROM sqlite_master WHERE name='oneshot_active'")" "consumed_at IS NULL"
db "INSERT INTO audit_events(agent, tool_name, decision, rule) VALUES('t','X','allow','seed')"
python3 "$BPY" init >/dev/null 2>&1; st=$?
eq "re-init exits 0" "$st" "0"
eq "re-init preserves rows" "$(db "SELECT count(*) FROM audit_events")" "1"
db "DELETE FROM audit_events"

echo "== T2: redact (pure function, goldens) =="
R() { printf '%s' "$1" | python3 "$BPY" redact --agent ops 2>/dev/null; }
out="$(R '{"tool_name":"Bash","tool_input":{"command":"curl --token abc123SECRET https://api.x.com"}}')"
lacks "bash --token value gone" "$out" "abc123SECRET"
has   "bash --token masked" "$out" "•••"
out="$(R '{"tool_name":"X","tool_input":{"api_key":"zzzKEYzzz","url":"https://ok"}}')"
lacks "api_key value gone" "$out" "zzzKEYzzz"
has   "api_key masked" "$out" "•••"
out="$(R '{"tool_name":"mcp__plugin_imessage_imessage__reply","tool_input":{"chat_id":"c1","text":"0123456789012345678901234567890123456789012345678EXTRA-TAIL-SHOULD-VANISH"}}')"
lacks "body tail gone" "$out" "EXTRA-TAIL-SHOULD-VANISH"
has   "body 48-prefix kept" "$out" "012345678901234567890123456789012345678901234567"
has   "body elision marker" "$out" "chars]"
out="$(R '{"tool_name":"Bash","tool_input":{"command":"echo ghp_ABCDEF1234567890abcd > f && cat token.txt"}}')"
lacks "ghp_ literal gone" "$out" "ghp_ABCDEF1234567890abcd"
out="$(R '{"tool_name":"Bash","tool_input":{"command":"AUTH=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U curl x"}}')"
lacks "JWT literal gone" "$out" "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
out="$(R '{"tool_name":"Bash","tool_input":{"command":"MY_API_TOKEN=supersecretvalue python3 run.py"}}')"
lacks "VAR=secret value gone" "$out" "supersecretvalue"
out="$(R "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/x\",\"data\":\"$(printf 'A%.0s' $(seq 1 5000))\"}}")"
if [ "${#out}" -le 2200 ]; then ok "2KB truncation (len=${#out})"; else bad "2KB truncation" "len=${#out}"; fi
one="$(R '{"tool_name":"Bash","tool_input":{"command":"curl --token abc123SECRET https://x"},"session_id":"s"}')"
two="$(printf '%s' "$one" | python3 "$BPY" redact --agent ops 2>/dev/null)"
eq "idempotent (redact∘redact = redact)" "$two" "$one"
out="$(printf 'raw text with ghp_ABCDEF1234567890abcd inside' | python3 "$BPY" redact --agent ops 2>/dev/null)"
lacks "non-JSON raw text still redacted" "$out" "ghp_ABCDEF1234567890abcd"

echo "== T3: hash (canonicalization v1) =="
h1="$(J Write '{"file_path":"/a","content":"x"}' | python3 "$BPY" hash --agent designer 2>/dev/null)"
h2="$(J Write '{"content":"x","file_path":"/a"}' | python3 "$BPY" hash --agent designer 2>/dev/null)"
h3="$(J Write '{"file_path":"/a","content":"y"}' | python3 "$BPY" hash --agent designer 2>/dev/null)"
h4="$(J Write '{"file_path":"/a","content":"x"}' | python3 "$BPY" hash --agent ops 2>/dev/null)"
eq "key-order invariant" "$h1" "$h2"
[ "$h1" != "$h3" ] && ok "distinct input => distinct hash" || bad "distinct input => distinct hash"
[ "$h1" != "$h4" ] && ok "agent is part of the hash" || bad "agent is part of the hash"
case "$h1" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#h1}" = "64" ] && ok "64-hex digest" || bad "64-hex digest" "len=${#h1}" ;;
  *) bad "64-hex digest" "got '$h1'" ;;
esac

echo "== T4: classify (riskclass two-axis, declared tools) =="
cp "$REF/riskclass.tsv" "$STORE/riskclass.tsv"
cp "$REF/schema.sql" "$STORE/schema.sql" 2>/dev/null || true
C() { python3 "$BPY" classify --agent "${2:-designer}" --tool "$1" 2>/dev/null; }
eq "Read -> READ" "$(C Read)" "READ	-"
eq "Write -> WRITE_LOCAL/file_path" "$(C Write)" "WRITE_LOCAL	file_path"
eq "imessage reply -> EXTERNAL/chat_id" "$(C mcp__plugin_imessage_imessage__reply)" "EXTERNAL	chat_id"
eq "unknown mcp__* -> EXTERNAL (fail toward gating)" "$(C mcp__new_server__do_thing)" "EXTERNAL	-"
eq "unknown non-MCP -> READ (current posture)" "$(C SomeBrandNewTool)" "READ	-"
mkdir -p "$STORE/riskclass.d"
printf 'WebFetch\tEXTERNAL\turl\tops override\n' > "$STORE/riskclass.d/ops.tsv"
eq "per-agent override wins" "$(C WebFetch ops)" "EXTERNAL	url"
eq "other agents unaffected by override" "$(C WebFetch designer)" "READ	-"

echo "== T5: audit + fallback =="
J mcp__plugin_imessage_imessage__reply '{"chat_id":"c-77","text":"hello there"}' \
  | python3 "$BPY" audit --agent designer --decision deny --rule "relational/outward-facing"; st=$?
eq "audit deny exits 0" "$st" "0"
J Bash '{"command":"git status"}' | python3 "$BPY" audit --agent designer --decision allow --rule "in-boundary bash"; st=$?
eq "audit allow exits 0" "$st" "0"
eq "2 audit rows" "$(db "SELECT count(*) FROM audit_events")" "2"
eq "hook_ms populated" "$(db "SELECT count(*) FROM audit_events WHERE hook_ms IS NOT NULL")" "2"
eq "resource extracted (chat_id)" "$(db "SELECT resource FROM audit_events WHERE decision='deny'")" "c-77"
J Bash '{"command":"curl --token abc123SECRET x"}' | python3 "$BPY" audit --agent designer --decision deny --rule t
lacks "audit row redacted" "$(db "SELECT redacted_input FROM audit_events ORDER BY id DESC LIMIT 1")" "abc123SECRET"
mv "$STORE/boundary.db" "$STORE/boundary.db.hidden"
J Bash '{"command":"x"}' | python3 "$BPY" audit --agent designer --decision deny --rule t 2>/dev/null; st=$?
eq "audit with DB gone still exits 0" "$st" "0"
[ -s "$STORE/audit-fallback.log" ] && ok "fallback flat-log line written" || bad "fallback flat-log line written"
rm -f "$STORE/boundary.db"; mv "$STORE/boundary.db.hidden" "$STORE/boundary.db"
db "DELETE FROM audit_events"

echo "== T6: enqueue (idempotent inbox) =="
DENYJ="$(J mcp__plugin_imessage_imessage__reply '{"chat_id":"c-77","text":"ping the owner"}')"
for i in 1 2 3; do printf '%s' "$DENYJ" | python3 "$BPY" enqueue --agent designer --tripwire "relational/outward-facing" --reason "MCP tool sends to a third party" --stub "$STORE/stub.md"; done
eq "3 identical denies -> 1 pending row" "$(db "SELECT count(*) FROM inbox_items WHERE agent='designer' AND status='pending'")" "1"
eq "seen_count bumped to 3" "$(db "SELECT seen_count FROM inbox_items WHERE agent='designer'")" "3"
eq "resource populated" "$(db "SELECT resource FROM inbox_items WHERE agent='designer'")" "c-77"
has "redacted_input populated (body elided)" "$(db "SELECT redacted_input FROM inbox_items WHERE agent='designer'")" "chat_id"
# pending-cap 50 (R6 flood guard): fill to cap with synthetic rows, then a NEW call must not enqueue
db "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<49) INSERT INTO inbox_items(agent, tool_name, riskclass, tripwire, reason, call_hash) SELECT 'designer','X','EXEC','t','cap-filler','fake-'||i FROM n"
eq "at cap (50 pending)" "$(db "SELECT count(*) FROM inbox_items WHERE agent='designer' AND status='pending'")" "50"
J Bash '{"command":"echo new-thing-51"}' | python3 "$BPY" enqueue --agent designer --tripwire t --reason r; st=$?
eq "51st enqueue exits 0" "$st" "0"
eq "51st NOT enqueued" "$(db "SELECT count(*) FROM inbox_items WHERE agent='designer' AND status='pending'")" "50"
eq "cap audited" "$(db "SELECT count(*) FROM audit_events WHERE decision='enqueue_capped'")" "1"
printf '%s' "$DENYJ" | python3 "$BPY" enqueue --agent designer --tripwire "relational/outward-facing" --reason r
eq "dedupe still works at cap (seen x4)" "$(db "SELECT seen_count FROM inbox_items WHERE agent='designer' AND call_hash NOT LIKE 'fake-%'")" "4"
db "DELETE FROM inbox_items WHERE call_hash LIKE 'fake-%'"

echo "== T7: inbox resolve (first-responder-wins, minting authority) =="
ITEM1="$(db "SELECT id FROM inbox_items WHERE agent='designer' LIMIT 1")"
python3 "$BPY" inbox resolve "$ITEM1" allow-once --by some-agent >/dev/null 2>&1; st=$?
eq "allow-once by non-owner refused (exit 4)" "$st" "4"
eq "item still pending after refusal" "$(db "SELECT status FROM inbox_items WHERE id=$ITEM1")" "pending"
python3 "$BPY" inbox resolve "$ITEM1" allow-once --by owner >/dev/null; st=$?
eq "allow-once by owner resolves" "$st" "0"
eq "one-shot minted" "$(db "SELECT count(*) FROM oneshot_grants WHERE minted_from=$ITEM1 AND consumed_at IS NULL")" "1"
eq "minted_by=owner" "$(db "SELECT minted_by FROM oneshot_grants WHERE minted_from=$ITEM1")" "owner"
out="$(python3 "$BPY" inbox resolve "$ITEM1" deny --by content 2>/dev/null)"; st=$?
eq "second resolve loses (exit 3)" "$st" "3"
has "loser told who won" "$out" "already resolved by owner"
# race: 20 parallel resolvers on a fresh item -> exactly one winner
J Bash '{"command":"race-target"}' | python3 "$BPY" enqueue --agent designer --tripwire t --reason race
ITEM2="$(db "SELECT id FROM inbox_items WHERE reason='race' AND agent='designer'")"
rm -f "$STORE/wins.txt"
i=1; while [ "$i" -le 20 ]; do
  (python3 "$BPY" inbox resolve "$ITEM2" deny --by "resolver-$i" >/dev/null 2>&1 && echo "resolver-$i" >> "$STORE/wins.txt") &
  i=$((i+1))
done
wait
eq "20 parallel resolves -> exactly 1 winner" "$(wc -l < "$STORE/wins.txt" | tr -d ' ')" "1"
eq "winner recorded on the item" "$(db "SELECT resolved_by FROM inbox_items WHERE id=$ITEM2")" "$(cat "$STORE/wins.txt")"

echo "== T8: standing-grant validation matrix =="
mkdir -p "$STORE/grants.d"
TAB="$(printf '\t')"
cat > "$STORE/grants.d/designer.tsv" <<EOF
# grant_id${TAB}automation_id${TAB}tool${TAB}target_arg${TAB}target_value${TAB}expires${TAB}ratified_by${TAB}ratified_on${TAB}note
g-0001${TAB}morning-brief${TAB}mcp__plugin_imessage_imessage__reply${TAB}chat_id${TAB}TARGET-1${TAB}2099-01-01${TAB}owner${TAB}2026-07-24${TAB}pilot
g-bad1${TAB}morning-brief${TAB}Read${TAB}chat_id${TAB}x${TAB}2099-01-01${TAB}owner${TAB}2026-07-24${TAB}not-external
g-bad2${TAB}morning-brief${TAB}Bash${TAB}command${TAB}x${TAB}2099-01-01${TAB}owner${TAB}2026-07-24${TAB}never-standing
g-bad3${TAB}-${TAB}mcp__plugin_imessage_imessage__reply${TAB}chat_id${TAB}x${TAB}2099-01-01${TAB}owner${TAB}2026-07-24${TAB}no-automation
g-bad4${TAB}morning-brief${TAB}mcp__plugin_imessage_imessage__reply${TAB}chat_id${TAB}x${TAB}2025-01-01${TAB}owner${TAB}2026-07-24${TAB}expired
g-bad5${TAB}morning-brief${TAB}mcp__plugin_imessage_imessage__reply${TAB}chat_id${TAB}x${TAB}2099-01-01${TAB}some-agent${TAB}2026-07-24${TAB}wrong-ratifier
EOF
out="$(python3 "$BPY" grants list --agent designer)"
has "valid row loads" "$out" "g-0001	morning-brief"
has "not-EXTERNAL flagged" "$out" "INVALID(tool-not-external)"
has "Bash flagged never-standing" "$out" "INVALID(never-standing-tool)"
has "missing automation_id flagged" "$out" "INVALID(no-automation-id)"
has "expired flagged" "$out" "INVALID(expired)"
has "wrong ratifier flagged" "$out" "INVALID(ratified-by-some-agent)"
python3 "$BPY" grants check --agent designer >/dev/null; st=$?
eq "grants check exits 1 on invalid rows" "$st" "1"

echo "== T9: gate (one-shot + standing + never-grant + fail-toward-blocking) =="
G() { printf '%s' "$1" | python3 "$BPY" gate --agent designer --tool "$2" --tripwire "$3" 2>/dev/null; }
# one-shot: the exact call approved in T7 allows ONCE, then denies
out="$(G "$DENYJ" mcp__plugin_imessage_imessage__reply relational/outward-facing)"; st=$?
eq "one-shot exact retry allows" "$st" "0"
has "gate names the one-shot rule" "$out" "oneshot:"
eq "consumption stamped on inbox item" "$(db "SELECT count(*) FROM inbox_items WHERE id=$ITEM1 AND consumed_at IS NOT NULL")" "1"
G "$DENYJ" mcp__plugin_imessage_imessage__reply relational/outward-facing >/dev/null; st=$?
eq "second identical call denies (consumed)" "$st" "1"
# different input (hash miss) denies
G "$(J mcp__plugin_imessage_imessage__reply '{"chat_id":"c-77","text":"DIFFERENT"}')" mcp__plugin_imessage_imessage__reply relational/outward-facing >/dev/null; st=$?
eq "hash miss denies" "$st" "1"
# 2 parallel retries on a fresh mint consume exactly once
J Bash '{"command":"parallel-consume"}' | python3 "$BPY" enqueue --agent designer --tripwire t --reason par
ITEM3="$(db "SELECT id FROM inbox_items WHERE reason='par'")"
python3 "$BPY" inbox resolve "$ITEM3" allow-once --by owner >/dev/null
PARJ="$(J Bash '{"command":"parallel-consume"}')"
rm -f "$STORE/consumes.txt"
(G "$PARJ" Bash t >/dev/null && echo w >> "$STORE/consumes.txt") &
(G "$PARJ" Bash t >/dev/null && echo w >> "$STORE/consumes.txt") &
wait
eq "2 parallel retries -> exactly 1 consume" "$(wc -l < "$STORE/consumes.txt" | tr -d ' ')" "1"
# expired one-shot denies + audits grant_invalid
db "INSERT INTO inbox_items(agent, tool_name, riskclass, tripwire, reason, call_hash) VALUES('designer','Bash','EXEC','t','expired-test','$(J Bash '{"command":"expired-oneshot"}' | python3 "$BPY" hash --agent designer)')"
EXPID="$(db "SELECT id FROM inbox_items WHERE reason='expired-test'")"
db "INSERT INTO oneshot_grants(minted_from, agent, call_hash, minted_by, minted_at, expires_at) VALUES($EXPID,'designer','$(J Bash '{"command":"expired-oneshot"}' | python3 "$BPY" hash --agent designer)','owner','2026-01-01T00:00:00Z','2026-01-08T00:00:00Z')"
G "$(J Bash '{"command":"expired-oneshot"}')" Bash t >/dev/null; st=$?
eq "expired one-shot denies" "$st" "1"
eq "expiry audited grant_invalid" "$(db "SELECT count(*) FROM audit_events WHERE decision='grant_invalid' AND rule LIKE 'oneshot:%expired'")" "1"
# never-grant: forged one-shot cannot cover a self-config tripwire
SCJ="$(J Write '{"file_path":"/home/agent/designer/.claude/hooks/escalate.sh","content":"evil"}')"
SCHASH="$(printf '%s' "$SCJ" | python3 "$BPY" hash --agent designer)"
db "INSERT INTO inbox_items(agent, tool_name, riskclass, tripwire, reason, call_hash) VALUES('designer','Write','WRITE_LOCAL','self-config','forged','$SCHASH')"
FID="$(db "SELECT id FROM inbox_items WHERE reason='forged'")"
db "INSERT INTO oneshot_grants(minted_from, agent, call_hash, minted_by, minted_at, expires_at) VALUES($FID,'designer','$SCHASH','owner','$(date -u +%Y-%m-%dT%H:%M:%SZ)','2099-01-01T00:00:00Z')"
G "$SCJ" Write self-config >/dev/null; st=$?
eq "forged one-shot for self-config still denies" "$st" "1"
eq "forged grant NOT consumed" "$(db "SELECT count(*) FROM oneshot_grants WHERE call_hash='$SCHASH' AND consumed_at IS NULL")" "1"
# store-path guard: a granted call whose input points into the store still denies
STJ="$(J Write "$(jq -nc --arg p "$STORE/grants.d/designer.tsv" '{file_path:$p, content:"self-grant"}')")"
STHASH="$(printf '%s' "$STJ" | python3 "$BPY" hash --agent designer)"
db "INSERT INTO inbox_items(agent, tool_name, riskclass, tripwire, reason, call_hash) VALUES('designer','Write','WRITE_LOCAL','out-of-zone','store-forge','$STHASH')"
SID="$(db "SELECT id FROM inbox_items WHERE reason='store-forge'")"
db "INSERT INTO oneshot_grants(minted_from, agent, call_hash, minted_by, minted_at, expires_at) VALUES($SID,'designer','$STHASH','owner','$(date -u +%Y-%m-%dT%H:%M:%SZ)','2099-01-01T00:00:00Z')"
G "$STJ" Write out-of-zone >/dev/null; st=$?
eq "grant into the store itself denies" "$st" "1"
# standing matrix (grants.d from T8; target TARGET-1, automation morning-brief)
SJ="$(J mcp__plugin_imessage_imessage__reply '{"chat_id":"TARGET-1","text":"morning brief"}')"
out="$(printf '%s' "$SJ" | AUTOMATION_ID=morning-brief python3 "$BPY" gate --agent designer --tool mcp__plugin_imessage_imessage__reply --tripwire relational/outward-facing 2>/dev/null)"; st=$?
eq "standing grant fires (right automation+target)" "$st" "0"
eq "gate names the standing rule" "$out" "standing:g-0001"
printf '%s' "$SJ" | python3 "$BPY" gate --agent designer --tool mcp__plugin_imessage_imessage__reply --tripwire relational/outward-facing >/dev/null 2>&1; st=$?
eq "no AUTOMATION_ID -> interactive -> no standing" "$st" "1"
printf '%s' "$SJ" | AUTOMATION_ID=other-cron python3 "$BPY" gate --agent designer --tool mcp__plugin_imessage_imessage__reply --tripwire relational/outward-facing >/dev/null 2>&1; st=$?
eq "wrong automation_id denies" "$st" "1"
printf '%s' "$(J mcp__plugin_imessage_imessage__reply '{"chat_id":"OTHER-TARGET","text":"x"}')" | AUTOMATION_ID=morning-brief python3 "$BPY" gate --agent designer --tool mcp__plugin_imessage_imessage__reply --tripwire relational/outward-facing >/dev/null 2>&1; st=$?
eq "wrong target denies" "$st" "1"
printf '%s' "$SJ" | AUTOMATION_ID=morning-brief python3 "$BPY" gate --agent designer --tool mcp__plugin_imessage_imessage__reply --tripwire spend >/dev/null 2>&1; st=$?
eq "spend tripwire never grants" "$st" "1"
printf '%s' "$(J Bash '{"command":"echo hi"}')" | AUTOMATION_ID=morning-brief python3 "$BPY" gate --agent designer --tool Bash --tripwire relational/outward-facing >/dev/null 2>&1; st=$?
eq "standing never covers Bash" "$st" "1"
# fail-toward-blocking: garbage stdin / missing DB
printf 'not json at all' | python3 "$BPY" gate --agent designer --tool Bash --tripwire t >/dev/null 2>&1; st=$?
[ "$st" -ne 0 ] && ok "garbage stdin -> non-zero (deny stands)" || bad "garbage stdin -> non-zero"
mv "$STORE/boundary.db" "$STORE/boundary.db.hidden"
G "$DENYJ" mcp__plugin_imessage_imessage__reply relational/outward-facing >/dev/null; st=$?
[ "$st" -ne 0 ] && ok "DB gone -> non-zero (deny stands)" || bad "DB gone -> non-zero"
rm -f "$STORE/boundary.db"; mv "$STORE/boundary.db.hidden" "$STORE/boundary.db"
# concurrency smoke: 20 parallel identical denies -> 1 pending row
CONJ="$(J Bash '{"command":"concurrent-deny"}')"
i=1; while [ "$i" -le 20 ]; do
  (printf '%s' "$CONJ" | python3 "$BPY" enqueue --agent spotter --tripwire t --reason con >/dev/null 2>&1) &
  i=$((i+1))
done
wait
eq "20 parallel identical denies -> 1 pending row" "$(db "SELECT count(*) FROM inbox_items WHERE agent='spotter'")" "1"
eq "seen_count reflects all 20" "$(db "SELECT seen_count FROM inbox_items WHERE agent='spotter'")" "20"

echo "== T7b: ctl wrappers =="
out="$(bash "$REF/bin/inboxctl" list --status resolved)"
has "inboxctl list shows resolved items" "$out" "#$ITEM1"
bash "$REF/bin/grantctl" check --agent designer >/dev/null 2>&1; st=$?
eq "grantctl check propagates exit 1" "$st" "1"
out="$(bash "$REF/bin/boundaryctl" report grants 2>/dev/null)"
has "boundaryctl report grants shows grant_invalid trail" "$out" "grant_invalid"

echo "== T11: reconcile =="
eq "reconcile exits 0" "$(python3 "$BPY" reconcile --agent nobody >/dev/null 2>&1; echo $?)" "0"
eq "reconcile empty for quiet agent" "$(python3 "$BPY" reconcile --agent nobody | wc -l | tr -d ' ')" "0"
db "INSERT INTO inbox_items(created_at, agent, tool_name, riskclass, tripwire, reason, call_hash) VALUES('2026-07-20T00:00:00Z','teacher','Bash','EXEC','outward','old pending thing','stale-1')"
out="$(python3 "$BPY" reconcile --agent teacher)"
has "pending>24h reminder" "$out" "pending > 24h"
has "reminder names the item" "$out" "old pending thing"
J Bash '{"command":"teacher-approved"}' | python3 "$BPY" enqueue --agent teacher --tripwire outward --reason appr
AID="$(db "SELECT id FROM inbox_items WHERE reason='appr'")"
python3 "$BPY" inbox resolve "$AID" allow-once --by owner >/dev/null
out="$(python3 "$BPY" reconcile --agent teacher)"
has "approved-unconsumed surfaced" "$out" "APPROVED"
has "approval names expiry" "$out" "expires"
G2() { printf '%s' "$1" | python3 "$BPY" gate --agent teacher --tool Bash --tripwire t 2>/dev/null; }
G2 "$(J Bash '{"command":"teacher-approved"}')" >/dev/null
out="$(python3 "$BPY" reconcile --agent teacher)"
lacks "consumed approval no longer surfaced" "$out" "APPROVED"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
