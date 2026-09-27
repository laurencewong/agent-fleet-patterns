#!/usr/bin/env bash
# runner.test.sh — behavior suite for runner.sh. Uses a fake `claude`, a fake
# fetch, and a fake transport in a temp dir. No network, no real LLM.
# Run: bash tests/runner.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$HERE/runner.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }

# ---- fixtures
JOB="$T/job"; mkdir -p "$JOB" "$T/bin"
cat > "$JOB/job.conf" <<'EOF'
JOB_NAME="test-job"
FETCH_CMD='[ "${FAKE_FETCH_RC:-0}" = 0 ] || exit "$FAKE_FETCH_RC"; printf -- "- item one: 340 stars\n- url: https://e.com/one\n" > "$FACTS"'
PROMPT_FILE="prompt.md"
SEND_CMD='cat >> "$STATE/sent.log"; echo "---" >> "$STATE/sent.log"; exit "${FAKE_SEND_RC:-0}"'
VERIFY_CMD='[ "${FAKE_VERIFY:-no}" = yes ]'
PROMOTE_CMD='echo promoted >> "$STATE/promote.log"'
EOF
echo "write the digest" > "$JOB/prompt.md"
# fake claude: prints FAKE_DRAFT, or sleeps (timeout test), or fails
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
[ -n "${FAKE_CLAUDE_RC:-}" ] && exit "$FAKE_CLAUDE_RC"
case "$*" in *"<facts>"*) ;; *) echo "facts not inlined" >&2; exit 9 ;; esac
printf '%s\n' "${FAKE_DRAFT:-Radar: 340 stars https://e.com/one}"
EOF
chmod +x "$T/bin/claude"

S="$JOB/state"
reset() { rm -rf "$S" "$JOB/scratch" "$T/logs"; }
run() { env CLAUDE_BIN="$T/bin/claude" RUNNER_LOG_DIR="$T/logs" RUNNER_LOCK_DIR="$T" "$@" bash "$RUNNER" "$JOB" >/dev/null 2>&1; echo $?; }
sends() { [ -f "$S/sent.log" ] && grep -c '^---$' "$S/sent.log" || echo 0; }
promos() { [ -f "$S/promote.log" ] && wc -l < "$S/promote.log" | tr -d ' ' || echo 0; }
lastsent() { cat "$S/lastsent" 2>/dev/null || echo none; }
TODAY="$(date +%F)"

echo "== happy path =="
reset
eq "exit 0"                      "$(run)" "0"
eq "sent once"                   "$(sends)" "1"
eq "promoted once"               "$(promos)" "1"
eq "lastsent = today"            "$(lastsent)" "$TODAY"
eq "outbox tee has the message"  "$(grep -c 'https://e.com/one' "$S/outbox.md")" "1"
eq "lock released"               "$([ -e "$T/runner-test-job.lock" ] && echo held || echo free)" "free"

echo "== same-day guard =="
eq "second run exits 0"          "$(run)" "0"
eq "no second send"              "$(sends)" "1"

echo "== dry run mutates nothing =="
reset
eq "dryrun exit 0"               "$(run DRYRUN=1)" "0"
eq "dryrun: no send"             "$(sends)" "0"
eq "dryrun: no promote"          "$(promos)" "0"
eq "dryrun: no lastsent"         "$(lastsent)" "none"

echo "== failed send: state untouched, next run retries =="
reset
eq "send fails -> exit 1"        "$(run FAKE_SEND_RC=1)" "1"
eq "send was attempted"          "$(sends)" "1"
eq "NOT promoted"                "$(promos)" "0"
eq "lastsent not written"        "$(lastsent)" "none"
eq "retry succeeds"              "$(run)" "0"
eq "promoted after retry"        "$(promos)" "1"

echo "== send 'fails' but source of truth shows delivered: promote, no retry =="
reset
eq "rc!=0 + verified -> exit 0"  "$(run FAKE_SEND_RC=1 FAKE_VERIFY=yes)" "0"
eq "promoted"                    "$(promos)" "1"
eq "next run is same-day guarded (no double-send)" "$(run)" "0"
eq "exactly one send total"      "$(sends)" "1"

echo "== grounding gate =="
reset
eq "invented number held"        "$(run FAKE_DRAFT='Radar: 3,400 stars https://e.com/one')" "1"
eq "held: nothing sent"          "$(sends)" "0"
eq "held draft kept for review"  "$([ -f "$S/held-$TODAY.txt" ] && echo yes)" "yes"
reset
eq "invented url held"           "$(run FAKE_DRAFT='Radar: 340 stars https://e.com/other')" "1"
eq "held: nothing sent"          "$(sends)" "0"
reset
eq "12k-style unit mismatch held" "$(run FAKE_DRAFT='Radar: 34k stars https://e.com/one')" "1"

echo "== claude timeout / failure =="
reset
eq "timeout -> exit 1"           "$(run FAKE_SLEEP=5 CLAUDE_TIMEOUT=1)" "1"
eq "timeout: nothing sent"       "$(sends)" "0"
grep -q "TIMED OUT" "$T/logs/runner-test-job.log" && eq "timeout logged" y y || eq "timeout logged" n y
reset
eq "claude rc!=0 -> exit 1"      "$(run FAKE_CLAUDE_RC=1)" "1"
eq "nothing sent"                "$(sends)" "0"

echo "== quiet day / fetch failure =="
reset
eq "quiet day exit 0"            "$(run FAKE_FETCH_RC=3)" "0"
eq "quiet: no send"              "$(sends)" "0"
eq "quiet: day marked"           "$(lastsent)" "$TODAY"
reset
eq "fetch failure -> exit 1"     "$(run FAKE_FETCH_RC=2)" "1"
eq "fetch failure: no lastsent"  "$(lastsent)" "none"

echo "== locks =="
reset
echo 999999 > "$T/runner-test-job.lock"             # dead pid
eq "stale lock cleared, run proceeds" "$(run)" "0"
eq "sent"                        "$(sends)" "1"
reset
sleep 30 & LIVE=$!
echo "$LIVE" > "$T/runner-test-job.lock"
eq "live lock -> skip (exit 0)"  "$(run)" "0"
eq "live lock: nothing sent"     "$(sends)" "0"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; rm -f "$T/runner-test-job.lock"

echo "== grounding_gate.py unit =="
G() { printf '%s' "$1" > "$T/d"; printf '%s' "$2" > "$T/f"; python3 "$HERE/grounding_gate.py" "$T/d" "$T/f" 2>/dev/null; echo $?; }
eq "separators normalized"       "$(G '1,232 comments' 'comments: 1232')" "0"
eq "k suffix normalized"         "$(G '12k stars' 'stars: 12000')" "0"
eq "decimal from facts"          "$(G '5.5 hours old' '(5.5h old)')" "0"
eq "small list markers allowed"  "$(G '1) first 2) second' 'nothing')" "0"
eq "digits inside a url ignored" "$(G 'https://e.com/item?id=4521' 'https://e.com/item?id=4521')" "0"
eq "invented percentage"         "$(G 'up 40%' 'up sharply')" "1"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
