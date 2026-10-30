#!/usr/bin/env bash
# capacity.sh — how full is the current Claude usage window right now.
#
# Prints one line:
#   window=<pct>% resets_in=<min>m state=<ok|tight|full>
#     ok    pct < TIGHT_PCT (default 70)
#     tight TIGHT_PCT <= pct <= FULL_PCT (default 85)
#     full  pct > FULL_PCT
#   No active block (between windows) -> window=0% resets_in=0m state=ok.
#
# Source: ccusage (`blocks --json`). Run it through a clean env so a broken
# node on PATH can't interfere, and write the output to a temp file before
# parsing. Piping ccusage straight into jq truncated the JSON more than once.
#
# Env:
#   CCUSAGE_CMD   command that prints `ccusage blocks --json` output
#                 (default: bunx ccusage blocks --json --token-limit max --offline)
#   CCUSAGE_JSON  path to a saved JSON file to parse instead (tests)
#   TIGHT_PCT / FULL_PCT  thresholds
set -u

TIGHT_PCT="${TIGHT_PCT:-70}"
FULL_PCT="${FULL_PCT:-85}"

TMP="$(mktemp "${TMPDIR:-/tmp}/capacity.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

if [ -n "${CCUSAGE_JSON:-}" ]; then
  cp "$CCUSAGE_JSON" "$TMP" 2>/dev/null
  RC=$?
elif [ -n "${CCUSAGE_CMD:-}" ]; then
  eval "$CCUSAGE_CMD" > "$TMP" 2>/dev/null
  RC=$?
else
  env -i HOME="$HOME" PATH=/usr/bin:/bin "$HOME/.bun/bin/bunx" ccusage blocks --json --token-limit max --offline > "$TMP" 2>/dev/null
  RC=$?
fi

idle() { echo "window=0% resets_in=0m state=ok"; exit 0; }
[ "$RC" -ne 0 ] || [ ! -s "$TMP" ] && idle

ACTIVE="$(jq -c '[.blocks[]? | select(.isActive == true)][0] // empty' "$TMP" 2>/dev/null)"
[ -z "$ACTIVE" ] && idle

TOTAL="$(printf '%s' "$ACTIVE" | jq -r '.totalTokens // 0')"
LIMIT="$(printf '%s' "$ACTIVE" | jq -r '.tokenLimitStatus.limit // 0')"
END_RAW="$(printf '%s' "$ACTIVE" | jq -r '.endTime // empty')"
{ [ -z "$LIMIT" ] || [ "$LIMIT" = "0" ] || [ -z "$END_RAW" ]; } && idle

PCT="$(awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN { printf "%d", (t / l * 100) + 0.5 }')"

# endTime is UTC ("2026-10-31T03:00:00.000Z"). Parse it AS UTC. Parsing it as
# local time put the reset hours off and made the alerts nonsense.
END_CLEAN="$(printf '%s' "$END_RAW" | sed -E 's/\.[0-9]+Z$//; s/Z$//')"
if date -j -u -f "%Y-%m-%dT%H:%M:%S" "$END_CLEAN" "+%s" >/dev/null 2>&1; then
  END_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$END_CLEAN" "+%s")"     # macOS
else
  END_EPOCH="$(date -u -d "${END_CLEAN}Z" "+%s" 2>/dev/null)"              # GNU
fi
NOW_EPOCH="$(date -u +%s)"
if [ -z "$END_EPOCH" ]; then
  MINUTES=0
else
  MINUTES=$(( (END_EPOCH - NOW_EPOCH) / 60 ))
  [ "$MINUTES" -lt 0 ] && MINUTES=0
fi

if   [ "$PCT" -gt "$FULL_PCT" ];  then STATE=full
elif [ "$PCT" -ge "$TIGHT_PCT" ]; then STATE=tight
else STATE=ok
fi

echo "window=${PCT}% resets_in=${MINUTES}m state=${STATE}"
