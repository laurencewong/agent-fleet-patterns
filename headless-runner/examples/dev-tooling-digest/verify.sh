#!/usr/bin/env bash
# verify.sh — did the message actually land? (stdin = the message body)
# Exit 0 only on POSITIVE evidence at the source of truth. "Can't tell" = 1,
# which makes the runner keep state untouched and retry next run.
#
# For the local-mailbox transport the source of truth is the mailbox file.
# For a real transport, query where the message lives: the chat app's message
# store, the provider's sent-items API, the channel history.
set -uo pipefail
BODY="$(cat)"
MAILBOX="${STATE:-./state}/mailbox.txt"
[ -n "${DELIVERY_URL:-}" ] && exit 1          # webhook: no read-back available
SHA="$(printf '%s' "$BODY" | shasum -a 256 | cut -c1-16)"   # match THIS body, not any earlier one
[ -f "$MAILBOX" ] && grep -qF -- "sha=$SHA" "$MAILBOX"
