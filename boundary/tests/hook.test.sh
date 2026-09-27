#!/usr/bin/env bash
# hook.test.sh — integration suite for examples/escalate.sh wired to a temp
# boundary store. Covers the interpreter bypass, self-config protection, the
# surrounding tripwires, and the full deny -> inbox -> allow-once -> retry loop
# through the real hook. Never touches a real agent dir or store.
# Run: bash tests/hook.test.sh
set -uo pipefail

REF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REF/examples/escalate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AGENT_DIR="$TMP/agent"; STORE="$TMP/store"; OUTSIDE="$HOME/.hook-test-outside-$$"   # classified only, never created
mkdir -p "$AGENT_DIR/notes" "$AGENT_DIR/.claude/hooks" "$STORE"
cp "$REF/boundary.py" "$REF/hooklib.sh" "$REF/schema.sql" "$REF/riskclass.tsv" "$STORE/"
FLEET_BOUNDARY="$STORE" python3 "$STORE/boundary.py" init >/dev/null

pass=0; fail=0
# run <allow|deny> <desc> <json> [extra env...]
run() {
  local expected="$1" desc="$2" json="$3" out decision; shift 3
  out="$(printf '%s' "$json" | env AGENT_HOME="$AGENT_DIR" FLEET_BOUNDARY="$STORE" AUDIT_SYNC=1 "$@" bash "$HOOK" 2>/dev/null)"
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ERROR"' 2>/dev/null)"
  if [ "$decision" = "$expected" ]; then
    pass=$((pass+1)); printf '  ok   [%s] %s\n' "$expected" "$desc"
  else
    fail=$((fail+1)); printf '  FAIL expected=%s got=%s — %s\n' "$expected" "$decision" "$desc"
  fi
}
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s — got %s want %s\n' "$1" "$2" "$3"; fi; }
b() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}, session_id:"s-hook"}'; }
w() { jq -nc --arg p "$1" '{tool_name:"Write", tool_input:{file_path:$p, content:"x"}, session_id:"s-hook"}'; }
db() { sqlite3 "$STORE/boundary.db" "$@"; }

echo "== interpreter / opaque-write fail closed =="
run deny  "python3 -c"                  "$(b "python3 -c 'pass'")"
run deny  "python3 -c rewriting the hook" "$(b "python3 -c 'open(\".claude/hooks/escalate.sh\",\"w\").write(\"exit 0\")'")"
run deny  "perl -e"                     "$(b "perl -e 'exit 0'")"
run deny  "node -e"                     "$(b "node -e 'process.exit(0)'")"
run deny  "node --eval"                 "$(b "node --eval 'x'")"
run deny  "ruby -e"                     "$(b "ruby -e 'exit'")"
run deny  "osascript -e"                "$(b "osascript -e 'beep'")"
run deny  "python3 heredoc"             "$(b "python3 <<PYX")"
run deny  "python3 bare dash"           "$(b "python3 - <<PY")"
run deny  "dd"                          "$(b "dd if=$AGENT_DIR/a of=$AGENT_DIR/b")"
run deny  "rsync"                       "$(b "rsync -a /tmp/src/ $AGENT_DIR/notes/")"
run deny  "patch"                       "$(b "patch -p1 $AGENT_DIR/x")"
run deny  "vim -es"                     "$(b "vim -es $AGENT_DIR/x")"
run deny  "eval"                        "$(b "eval echo hi")"
run deny  "source"                      "$(b "source $AGENT_DIR/env.sh")"
run allow "python3 --version (FP regression)" "$(b "python3 --version")"
run allow "python3 --help (FP regression)"    "$(b "python3 --help")"
run allow "python3 -m module"           "$(b "python3 -m pytest -q")"
run allow "python3 script.py"           "$(b "python3 $AGENT_DIR/notes/main.py")"

echo "== self-config =="
run deny  "Write own hook"              "$(w "$AGENT_DIR/.claude/hooks/escalate.sh")"
run deny  "Write own settings (relative)" "$(w ".claude/settings.json")"
run deny  "Write into boundary store"   "$(w "$STORE/grants.d/content.tsv")"
run deny  "redirect into own hook"      "$(b "echo 'exit 0' > $AGENT_DIR/.claude/hooks/escalate.sh")"
run deny  "cp over own settings"        "$(b "cp /tmp/x $AGENT_DIR/.claude/settings.json")"
run deny  "agent runs inboxctl"         "$(b "bash inboxctl resolve 1 allow-once --by owner")"
run deny  "agent runs boundary.py"      "$(b "python3 $STORE/boundary.py inbox resolve 1 allow-once --by owner")"

echo "== zone + surrounding tripwires =="
run allow "Write inside zone"           "$(w "$AGENT_DIR/notes/x.md")"
run allow "Write relative inside zone"  "$(w "notes/y.md")"
run allow "Write to temp"               "$(w "/tmp/scratch-$$.txt")"
run deny  "Write outside zone"          "$(w "$OUTSIDE/x.md")"
run allow "Write in an extra root"      "$(w "$OUTSIDE/x.md")" AGENT_EXTRA_ROOTS="$OUTSIDE"
run allow "echo redirect in zone"       "$(b "echo ok > $AGENT_DIR/notes/note.txt")"
run deny  "redirect outside zone"       "$(b "echo hi > $OUTSIDE/y.txt")"
run allow "2>/dev/null is not a write"  "$(b "ls /etc 2>/dev/null")"
run allow "git status"                  "$(b "git status")"
run allow "git checkout -b is not spend" "$(b "git checkout -b fix-selector")"
run deny  "git push"                    "$(b "git push origin main")"
run deny  "curl POST remote"            "$(b "curl -X POST https://api.example.com/x -d a=1")"
run allow "curl GET"                    "$(b "curl -s https://example.com")"
run deny  "rm -rf"                      "$(b "rm -rf $AGENT_DIR/notes")"
run deny  "stripe"                      "$(b "stripe charges create --amount 100")"
run deny  "MCP send tool"               "$(jq -nc '{tool_name:"mcp__plugin_imessage_imessage__reply", tool_input:{chat_id:"c-1",text:"hi"}}')"
run deny  "browser click tool"          "$(jq -nc '{tool_name:"mcp__browser__computer", tool_input:{action:"left_click"}}')"
run allow "browser read tool"           "$(jq -nc '{tool_name:"mcp__browser__get_page_text", tool_input:{}}')"
run allow "Read"                        "$(jq -nc '{tool_name:"Read", tool_input:{file_path:"/etc/hosts"}}')"

echo "== deny -> inbox -> allow-once -> retry succeeds once (through the hook) =="
PUSH="$(b "git push origin feature-x")"
run deny  "push denied"                 "$PUSH"
run deny  "same push again (dedupes)"   "$PUSH"
eq "one pending inbox row for the repeated call" "$(db "SELECT count(*) FROM inbox_items WHERE status='pending' AND redacted_input LIKE '%feature-x%'")" "1"
eq "seen_count = 2"                     "$(db "SELECT seen_count FROM inbox_items WHERE redacted_input LIKE '%feature-x%'")" "2"
ID="$(db "SELECT id FROM inbox_items WHERE redacted_input LIKE '%feature-x%'")"
FLEET_BOUNDARY="$STORE" bash "$REF/bin/inboxctl" resolve "$ID" allow-once --by owner >/dev/null
run allow "exact retry allowed by one-shot" "$PUSH"
run deny  "second retry denied (consumed)"  "$PUSH"
run deny  "different push still denied"     "$(b "git push origin main")"
eq "grant use audited" "$(db "SELECT count(*) FROM audit_events WHERE decision='allow' AND rule LIKE 'granted: oneshot:%'")" "1"
ls "$AGENT_DIR/escalations/"*.md >/dev/null 2>&1 && eq "escalation stub rendered" "yes" "yes" || eq "escalation stub rendered" "no" "yes"

echo "== secrets never reach the stub or the audit trail =="
run deny  "push with token in URL"      "$(b "git push https://x:ghp_ABCDEF1234567890abcd@github.com/o/r.git")"
if grep -rq "ghp_ABCDEF1234567890abcd" "$AGENT_DIR/escalations" "$AGENT_DIR/decisions-log.md"; then eq "stub redacted" "leaked" "clean"; else eq "stub redacted" "clean" "clean"; fi
eq "audit redacted" "$(db "SELECT count(*) FROM audit_events WHERE redacted_input LIKE '%ghp_ABCDEF%'")" "0"

echo "== fail toward blocking: store gone, denies still stand =="
run deny  "git push with store deleted" "$(b "git push origin z")" FLEET_BOUNDARY="$TMP/nope"
run allow "allow path unaffected"       "$(b "git status")" FLEET_BOUNDARY="$TMP/nope"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
