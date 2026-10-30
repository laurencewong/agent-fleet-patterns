#!/usr/bin/env bash
# dispatcher.test.sh — capacity.sh against saved ccusage JSON, and
# reply-watchdog.sh against a throwaway chat.db with a fake transport.
# No network, no real messages, no real model.
# Run: bash dispatcher/tests/dispatcher.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  ok   %s\n' "$1";; *) fail=$((fail+1)); printf '  FAIL %s — [%s] lacks [%s]\n' "$1" "$2" "$3";; esac; }

iso_in() {  # UTC ISO timestamp N minutes from now
  local e=$(( $(date -u +%s) + $1 * 60 ))
  date -u -r "$e" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -d "@$e" '+%Y-%m-%dT%H:%M:%S.000Z'
}
block() {  # tokens limit end_minutes_from_now
  printf '{"blocks":[{"isActive":false,"totalTokens":1,"tokenLimitStatus":{"limit":10}},{"isActive":true,"totalTokens":%s,"tokenLimitStatus":{"limit":%s},"endTime":"%s"}]}' "$1" "$2" "$(iso_in "$3")"
}

echo "capacity.sh"
block 10 100 120 > "$T/ok.json";    out="$(CCUSAGE_JSON="$T/ok.json" "$HERE/capacity.sh")"
has "10% is ok"            "$out" "window=10% "
has "ok state"             "$out" "state=ok"
m="${out#*resets_in=}"; m="${m%%m *}"
eq  "reset ~120m (UTC parse)" "$([ "$m" -ge 118 ] && [ "$m" -le 120 ] && echo y || echo "$m")" "y"
block 75 100 30 > "$T/tight.json"; out="$(CCUSAGE_JSON="$T/tight.json" "$HERE/capacity.sh")"
has "75% is tight"         "$out" "state=tight"
block 90 100 30 > "$T/full.json";  out="$(CCUSAGE_JSON="$T/full.json" "$HERE/capacity.sh")"
has "90% is full"          "$out" "state=full"
echo '{"blocks":[]}' > "$T/none.json"; out="$(CCUSAGE_JSON="$T/none.json" "$HERE/capacity.sh")"
eq  "no active block"      "$out" "window=0% resets_in=0m state=ok"
: > "$T/empty.json";               out="$(CCUSAGE_JSON="$T/empty.json" "$HERE/capacity.sh")"
eq  "empty output"         "$out" "window=0% resets_in=0m state=ok"
block 50 100 -10 > "$T/past.json"; out="$(CCUSAGE_JSON="$T/past.json" "$HERE/capacity.sh")"
has "past reset clamps to 0" "$out" "resets_in=0m"

echo "reply-watchdog.sh"
DB="$T/chat.db"
sqlite3 "$DB" "
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER, handle_id INTEGER);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT);
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
INSERT INTO handle VALUES (1,'+15555550100'),(2,'+15555550199');
INSERT INTO chat VALUES (1,'any;-;+15555550100'),(2,'any;+;GROUP1'),(3,'any;-;+15555550199');"
apple() { echo $(( ($(date +%s) - $1 * 60 - 978307200) * 1000000000 )); }   # N minutes ago
msg() { sqlite3 "$DB" "INSERT INTO message VALUES ($1, $(apple "$2"), $3, $4); INSERT INTO chat_message_join VALUES ($5, $1);"; }

cat > "$T/send.sh" <<'S'
#!/usr/bin/env bash
{ echo "to=$1"; cat; } >> "$SENT_LOG"; exit "${FAKE_SEND_RC:-0}"
S
chmod +x "$T/send.sh"
export OWNER_HANDLE="+15555550100" CHAT_GUIDS="any;-;+15555550100 any;+;GROUP1" \
  ALERT_CHAT="any;-;+15555550100" SEND_CMD="$T/send.sh" DB_PATH="$DB" \
  STATE_DIR="$T/state" ACTIVE_HOURS="0-24" SENT_LOG="$T/sent.log" \
  CAPACITY_CMD="echo window=42% resets_in=60m state=ok"
W="$HERE/reply-watchdog.sh"
reset() { sqlite3 "$DB" "DELETE FROM message; DELETE FROM chat_message_join;"; }
sent() { [ -f "$T/sent.log" ] && grep -c '^to=' "$T/sent.log" || echo 0; }

msg 1 5 0 1 1
out="$("$W")";            has "fresh message: no alert"   "$out" "within grace"
eq  "nothing sent"        "$(sent)" "0"

reset; msg 2 30 0 1 1; msg 3 25 1 0 1
out="$("$W")";            has "answered: no alert"        "$out" "answered"

reset; msg 4 20 0 1 2
out="$("$W" --dry-run)";  has "stale group msg: would alert" "$out" "WOULD ALERT rowid=4"
eq  "dry run sends nothing" "$(sent)" "0"
eq  "dry run writes no state" "$([ -f "$T/state/last-alerted-rowid" ] && echo y || echo n)" "n"

out="$("$W")";            has "stale: alert sent"         "$out" "alert sent for rowid=4"
eq  "one message sent"    "$(sent)" "1"
has "alert goes to DM"    "$(cat "$T/sent.log")" "to=any;-;+15555550100"
has "alert carries capacity" "$(cat "$T/sent.log")" "window=42%"

out="$("$W")";            has "same rowid not repeated"   "$out" "already alerted"
eq  "still one sent"      "$(sent)" "1"

msg 5 18 0 2 3
out="$("$W")";            has "other people ignored"      "$out" "already alerted"

reset; msg 6 16 0 1 1
FAKE_SEND_RC=1 "$W" >/dev/null; rc=$?
eq  "failed send exits 1" "$rc" "1"
eq  "failed send not marked" "$(cat "$T/state/last-alerted-rowid")" "4"
out="$("$W")";            has "retried next tick"         "$out" "alert sent for rowid=6"

out="$(ACTIVE_HOURS="0-0" "$W" --dry-run)"; has "quiet hours exit" "$out" "outside active hours"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
