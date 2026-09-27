#!/usr/bin/env bash
# send.sh — delivery transport (stdin = message body). Exit 0 = sent.
#
# Example transport: POST to a push-notification webhook if DELIVERY_URL is set;
# otherwise append to a local mailbox file so the example runs anywhere.
# The original fleet used an AppleScript messaging shim here. That transport
# could report a timeout AFTER the message was delivered, which is why the
# runner consults verify.sh before treating a failure as a failure.
set -uo pipefail
BODY="$(cat)"
MAILBOX="${STATE:-./state}/mailbox.txt"
if [ -n "${DELIVERY_URL:-}" ]; then
  printf '%s' "$BODY" | curl -fsS --max-time 30 -H "Title: Agent Tooling Radar" --data-binary @- "$DELIVERY_URL" >/dev/null
else
  mkdir -p "$(dirname "$MAILBOX")"
  SHA="$(printf '%s' "$BODY" | shasum -a 256 | cut -c1-16)"
  { printf '%s\n' "--- $(date '+%F %T') sha=$SHA"; printf '%s\n' "$BODY"; } >> "$MAILBOX"
fi
