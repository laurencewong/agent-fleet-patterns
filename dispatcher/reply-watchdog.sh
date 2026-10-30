#!/usr/bin/env bash
# reply-watchdog.sh — did the live agent session answer the human?
#
# Runs from launchd every 5 minutes. Finds the newest inbound message from the
# owner in the watched chats. If it is older than STALE_MIN and nothing has
# been sent back in that same chat since, the live session is probably busy,
# rate-limited or dead. Send ONE alert per message, from outside the model,
# with the current capacity line so the human can tell which.
#
# This reads the macOS Messages database (chat.db) read-only. The process
# running it needs Full Disk Access. Swap the two queries for your own
# transport (Slack, Telegram, a log file) and the rest stays the same.
#
# Config (env, or a file passed as WATCHDOG_CONF):
#   OWNER_HANDLE   the human's handle as stored in chat.db (e.g. +15555550100)
#   CHAT_GUIDS     space-separated chat GUIDs to watch (DM, family group, ...)
#   ALERT_CHAT     chat GUID that gets the alert (usually the DM)
#   SEND_CMD       command that reads a message on stdin and sends it to $1
#   CAPACITY_CMD   default: ./capacity.sh next to this script
#   STATE_DIR      where the last-alerted ROWID is kept
#   DB_PATH        default: $HOME/Library/Messages/chat.db
#   STALE_MIN      default 15
#   ACTIVE_HOURS   "6-23": only check between these local hours
#
# Usage: reply-watchdog.sh [--dry-run]
#   --dry-run  print what would be sent and why; send nothing, write no state.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${WATCHDOG_CONF:-}" ] && . "$WATCHDOG_CONF"

: "${OWNER_HANDLE:?set OWNER_HANDLE}"
: "${CHAT_GUIDS:?set CHAT_GUIDS}"
: "${ALERT_CHAT:?set ALERT_CHAT}"
: "${SEND_CMD:?set SEND_CMD}"
CAPACITY_CMD="${CAPACITY_CMD:-\"$HERE/capacity.sh\"}"
STATE_DIR="${STATE_DIR:-$HOME/.reply-watchdog}"
DB_PATH="${DB_PATH:-$HOME/Library/Messages/chat.db}"
STALE_MIN="${STALE_MIN:-15}"
ACTIVE_HOURS="${ACTIVE_HOURS:-6-23}"
STATE_FILE="$STATE_DIR/last-alerted-rowid"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
mkdir -p "$STATE_DIR"

# --- quiet hours. Gate here, not in the plist: StartInterval fires all day.
H_START="${ACTIVE_HOURS%-*}"; H_END="${ACTIVE_HOURS#*-}"
HOUR=$((10#$(date +%H)))   # base 10, or 08 and 09 read as bad octal
if [ "$HOUR" -lt "$H_START" ] || [ "$HOUR" -ge "$H_END" ]; then
  [ "$DRY_RUN" -eq 1 ] && say "outside active hours ($ACTIVE_HOURS), exiting"
  exit 0
fi

# Single-quote-escape each GUID into a SQL IN list.
IN_LIST=""
for g in $CHAT_GUIDS; do
  g_esc="$(printf '%s' "$g" | sed "s/'/''/g")"
  IN_LIST="${IN_LIST:+$IN_LIST,}'$g_esc'"
done
OWNER_ESC="$(printf '%s' "$OWNER_HANDLE" | sed "s/'/''/g")"

# chat.db dates are Apple-epoch nanoseconds: unix = date/1e9 + 978307200.
ROW="$(sqlite3 -separator '|' "file:$DB_PATH?mode=ro" "
SELECT m.ROWID, m.date, c.ROWID
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
JOIN chat c ON c.ROWID = cmj.chat_id
JOIN handle h ON h.ROWID = m.handle_id
WHERE m.is_from_me = 0 AND h.id = '$OWNER_ESC' AND c.guid IN ($IN_LIST)
ORDER BY m.date DESC LIMIT 1;" 2>/dev/null)"

if [ -z "$ROW" ]; then
  say "no inbound message from owner in watched chats"
  exit 0
fi

MSG_ROWID="${ROW%%|*}"; REST="${ROW#*|}"
MSG_DATE="${REST%%|*}"; CHAT_ROWID="${REST#*|}"
MSG_EPOCH=$(( MSG_DATE / 1000000000 + 978307200 ))
AGE_MIN=$(( ($(date +%s) - MSG_EPOCH) / 60 ))
MSG_HHMM="$(date -r "$MSG_EPOCH" '+%H:%M' 2>/dev/null || date -d "@$MSG_EPOCH" '+%H:%M')"

if [ "$AGE_MIN" -lt "$STALE_MIN" ]; then
  say "newest inbound rowid=$MSG_ROWID is ${AGE_MIN}m old, within grace, no alert"
  exit 0
fi

REPLIES="$(sqlite3 "file:$DB_PATH?mode=ro" "
SELECT COUNT(*) FROM message m2
JOIN chat_message_join cmj2 ON cmj2.message_id = m2.ROWID
WHERE cmj2.chat_id = $CHAT_ROWID AND m2.is_from_me = 1 AND m2.date > $MSG_DATE;" 2>/dev/null)"
if [ "${REPLIES:-0}" -gt 0 ]; then
  say "rowid=$MSG_ROWID answered ($REPLIES outbound since), no alert"
  exit 0
fi

# ROWIDs only go up, so "already alerted on >= this ROWID" is enough to dedupe.
LAST=0
[ -f "$STATE_FILE" ] && LAST="$(cat "$STATE_FILE")"
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ "$MSG_ROWID" -le "$LAST" ]; then
  say "rowid=$MSG_ROWID already alerted, not repeating"
  exit 0
fi

CAP="$(eval "$CAPACITY_CMD" 2>/dev/null)"; CAP="${CAP:-capacity unknown}"
BODY="⚠️ Your last message (sent ${MSG_HHMM}) has no reply after ${AGE_MIN} min. The live session may be busy, rate-limited or down. Capacity: ${CAP}."

if [ "$DRY_RUN" -eq 1 ]; then
  say "WOULD ALERT rowid=$MSG_ROWID age=${AGE_MIN}m"
  echo "$BODY"
  exit 0
fi

if printf '%s\n' "$BODY" | eval "$SEND_CMD \"\$ALERT_CHAT\""; then
  say "alert sent for rowid=$MSG_ROWID"
else
  say "send failed for rowid=$MSG_ROWID (rc=$?); not marking as alerted"
  exit 1
fi
echo "$MSG_ROWID" > "$STATE_FILE"
