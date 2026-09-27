#!/usr/bin/env bash
# runner.sh <job-dir> — reliable cron-driven `claude -p` job.
#
# One launchd/cron entry per job. The job dir holds job.conf (see
# examples/dev-tooling-digest/job.conf) plus whatever scripts it names.
#
#   0. lock (stale-lock aware) + same-day guard
#   1. FETCH    deterministic; writes $SCRATCH/facts.md (+ anything else)
#               exit 3 = quiet day
#   2. DRAFT    claude -p sees ONLY the facts file, inlined into the prompt.
#               No tools, so it can't fetch, send, or wander. Hard timeout.
#   3. GROUND   deterministic gate: every number and URL in the draft must
#               appear in the facts. Fail = hold the draft, send nothing.
#   4. SEND     deterministic shell. A non-zero exit is NOT proof of
#               non-delivery: if VERIFY_CMD is set, check the source of truth
#               before deciding. Never blind-retry (that's how double-sends happen).
#   5. PROMOTE  seen-state + lastsent + outbox tee, ONLY after a confirmed send.
#               A failed send leaves state untouched, so the next run retries
#               with nothing lost.
#
# Env: DRYRUN=1 (run 0-3, print the draft, mutate nothing)
#      CLAUDE_BIN (default: claude)  CLAUDE_TIMEOUT (default 300s)
#      RUNNER_STATE / RUNNER_SCRATCH / RUNNER_LOG_DIR / RUNNER_LOCK_DIR (overrides)
#
# Exit: 0 done / skipped / quiet · 1 failure (state untouched) · 2 usage
set -u
set -o pipefail

JOB_DIR="${1:-}"
[ -n "$JOB_DIR" ] && [ -f "$JOB_DIR/job.conf" ] || { echo "usage: runner.sh <job-dir with job.conf>" >&2; exit 2; }
JOB_DIR="$(cd "$JOB_DIR" && pwd)"
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paths job.conf may reference (set before sourcing it).
STATE="${RUNNER_STATE:-$JOB_DIR/state}"
SCRATCH="${RUNNER_SCRATCH:-$JOB_DIR/scratch}"
FACTS="$SCRATCH/facts.md"
DRAFT="$SCRATCH/draft.txt"

# ---- job config: JOB_NAME FETCH_CMD PROMPT_FILE SEND_CMD [VERIFY_CMD] [PROMOTE_CMD] [QUIET_DAY]
# shellcheck source=/dev/null
. "$JOB_DIR/job.conf"
: "${JOB_NAME:?job.conf must set JOB_NAME}" "${FETCH_CMD:?}" "${PROMPT_FILE:?}" "${SEND_CMD:?}"
VERIFY_CMD="${VERIFY_CMD:-}"
PROMOTE_CMD="${PROMOTE_CMD:-}"
QUIET_DAY="${QUIET_DAY:-silent}"          # silent | send
DRYRUN="${DRYRUN:-0}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-300}"

LOG_DIR="${RUNNER_LOG_DIR:-$HOME/Library/Logs}"
LOCK="${RUNNER_LOCK_DIR:-${TMPDIR:-/tmp}}/runner-${JOB_NAME}.lock"
LOG="$LOG_DIR/runner-${JOB_NAME}.log"
SENT_MARK="$STATE/lastsent"
OUTBOX="${OUTBOX:-$STATE/outbox.md}"      # context bridge: what went out, for the live session

# launchd starts jobs with a near-empty env: pin PATH and a UTF-8 locale.
# Without the locale, some send transports silently mangle non-ASCII text.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
export JOB_DIR STATE SCRATCH FACTS DRAFT DRYRUN

mkdir -p "$STATE" "$SCRATCH" "$LOG_DIR"
ts()  { date "+%Y-%m-%d %H:%M:%S %Z"; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG"; }

# ---- 0a. lock: skip if a live run holds it; clear it if its pid is dead
if [ -e "$LOCK" ]; then
  PID="$(cat "$LOCK" 2>/dev/null || echo "?")"
  if [ "$PID" != "?" ] && kill -0 "$PID" 2>/dev/null; then log "skip: run active (pid $PID)"; exit 0; fi
  log "stale lock (pid $PID), clearing"; rm -f "$LOCK"
fi
echo $$ > "$LOCK"; trap 'rm -f "$LOCK"' EXIT
log "=== start job=$JOB_NAME dryrun=$DRYRUN ==="

# ---- 0b. same-day guard: launchd re-fires on wake; a job must not double-send
TODAY="$(date +%F)"
if [ "$DRYRUN" != "1" ] && [ "$(cat "$SENT_MARK" 2>/dev/null)" = "$TODAY" ]; then
  log "same-day guard: already sent $TODAY"; exit 0
fi

# ---- 0c. optional: surface approved/pending boundary-inbox items to the log
if [ -n "${FLEET_BOUNDARY:-}" ] && [ -f "$FLEET_BOUNDARY/boundary.py" ]; then
  python3 "$FLEET_BOUNDARY/boundary.py" reconcile --agent "$JOB_NAME" >> "$LOG" 2>&1 || true
fi

# ---- 1. FETCH (deterministic). Clear per-run outputs first: yesterday's
# facts must never feed today's draft.
rm -f "$FACTS" "$DRAFT"
( cd "$JOB_DIR" && eval "$FETCH_CMD" ) >> "$LOG" 2>&1
RC=$?
if [ "$RC" -eq 3 ]; then
  log "quiet day: nothing cleared the floor"
  if [ "$QUIET_DAY" = "send" ]; then
    printf 'Quiet today. Nothing above the noise floor.\n' > "$DRAFT"
  else
    [ "$DRYRUN" = "1" ] || echo "$TODAY" > "$SENT_MARK"
    log "=== done (quiet, silent) ==="; exit 0
  fi
elif [ "$RC" -ne 0 ]; then
  log "fatal: fetch rc=$RC"; exit 1
fi

# ---- 2. DRAFT (LLM). Facts are inlined; the model gets no tools.
if [ ! -s "$DRAFT" ]; then
  [ -s "$FACTS" ] || { log "fatal: fetch produced no facts"; exit 1; }
  PROMPT="$(cat "$JOB_DIR/$PROMPT_FILE")

<facts>
$(cat "$FACTS")
</facts>"
  log "invoking claude (timeout ${CLAUDE_TIMEOUT}s)"
  # perl alarm = portable timeout (macOS has no coreutils `timeout`).
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$CLAUDE_TIMEOUT" \
    "$CLAUDE_BIN" -p "$PROMPT" --output-format text > "$DRAFT.tmp" 2>> "$LOG"
  CRC=$?
  if [ "$CRC" -eq 142 ]; then log "fatal: claude TIMED OUT after ${CLAUDE_TIMEOUT}s"; rm -f "$DRAFT.tmp"; exit 1; fi
  [ "$CRC" -eq 0 ] || { log "fatal: claude rc=$CRC"; rm -f "$DRAFT.tmp"; exit 1; }
  mv "$DRAFT.tmp" "$DRAFT"
fi
[ -s "$DRAFT" ] || { log "fatal: empty draft"; exit 1; }

# ---- 3. GROUND (deterministic). Prompts are requests, not invariants.
if [ -s "$FACTS" ]; then
  if ! python3 "$RUNNER_DIR/grounding_gate.py" "$DRAFT" "$FACTS" >> "$LOG" 2>&1; then
    cp "$DRAFT" "$STATE/held-$TODAY.txt"
    log "HELD: draft failed grounding gate; kept at $STATE/held-$TODAY.txt; nothing sent, state untouched"
    exit 1
  fi
fi
log "draft grounded ($(wc -c < "$DRAFT" | tr -d ' ') bytes)"

if [ "$DRYRUN" = "1" ]; then
  log "DRYRUN: not sending, no state mutation"; sed 's/^/    /' "$DRAFT" >> "$LOG"
  cat "$DRAFT"
  log "=== done (dryrun) ==="; exit 0
fi

# ---- 4. SEND (deterministic). rc!=0 might still have delivered.
( cd "$JOB_DIR" && eval "$SEND_CMD" ) < "$DRAFT" >> "$LOG" 2>&1
SRC=$?
if [ "$SRC" -ne 0 ]; then
  if [ -n "$VERIFY_CMD" ] && ( cd "$JOB_DIR" && eval "$VERIFY_CMD" ) < "$DRAFT" >> "$LOG" 2>&1; then
    log "send rc=$SRC but VERIFIED delivered at the source of truth; promoting (no retry)"
  else
    log "fatal: send rc=$SRC, not verified delivered; state untouched, next run retries"
    exit 1
  fi
fi

# ---- 5. PROMOTE: only reached after a confirmed send.
if [ -n "$PROMOTE_CMD" ]; then
  ( cd "$JOB_DIR" && eval "$PROMOTE_CMD" ) >> "$LOG" 2>&1 || log "warn: promote failed (send succeeded; items may repeat once)"
fi
echo "$TODAY" > "$SENT_MARK"
{ printf '\n## %s (%s)\n\n' "$JOB_NAME" "$(ts)"; cat "$DRAFT"; printf '\n'; } >> "$OUTBOX"
log "=== done job=$JOB_NAME ==="
