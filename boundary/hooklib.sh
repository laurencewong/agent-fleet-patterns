#!/usr/bin/env bash
# hooklib.sh — glue sourced by each agent's PreToolUse hook (examples/escalate.sh).
# bash 3.2. Defines fb_gate / fb_audit / fb_enqueue / fb_redact over the store
# at $FLEET_BOUNDARY. The hook remains the enforcer: fb_gate is the ONLY
# function that can change a decision, and only from deny -> grant-backed
# allow. Everything else is observability and MUST never block or crash a
# tool call (fail-toward-blocking).
#
# Contracts (all read the hook INPUT json on stdin):
#   fb_gate    <agent> <tool> <tripwire>   stdout rule, exit 0  iff a grant covers the call
#   fb_audit   <agent> <decision> <rule>   always exit 0; async unless AUDIT_SYNC=1
#   fb_enqueue <agent> <tripwire> <reason> always exit 0; async unless AUDIT_SYNC=1
#   fb_redact  <agent> <text>  (arg, not stdin)  stdout redacted text; on redactor
#              failure prints a safe placeholder, NEVER the raw text.

FB_BPY="${FLEET_BOUNDARY:-}/boundary.py"

fb_gate() {
  if [ ! -f "$FB_BPY" ]; then cat >/dev/null 2>&1; return 1; fi
  python3 "$FB_BPY" gate --agent "$1" --tool "$2" --tripwire "$3" 2>/dev/null
}

_fb_audit_run()   { python3 "$FB_BPY" audit   --agent "$1" --decision "$2" --rule "$3" >/dev/null 2>&1; }
_fb_enqueue_run() { python3 "$FB_BPY" enqueue --agent "$1" --tripwire "$2" --reason "$3" >/dev/null 2>&1; }

# Both readers below capture stdin BEFORE going async: bash (no job control)
# gives a `&` command an implicit </dev/null, so backgrounding the python
# directly made it read EMPTY hook input — every audit row landed tool_name='?'
# with no session/payload (found after ~1,700 blind rows had piled up). The explicit
# pipe into the background job overrides that redirection. Capture is cheap
# (the hook JSON is already in the pipe buffer) and still never blocks a call.

fb_audit() {
  local _fb_in
  if [ ! -f "$FB_BPY" ]; then cat >/dev/null 2>&1; return 0; fi
  _fb_in="$(cat 2>/dev/null)"
  if [ -n "${AUDIT_SYNC:-}" ]; then printf '%s' "$_fb_in" | _fb_audit_run "$@"
  else ( printf '%s' "$_fb_in" | _fb_audit_run "$@" & ) 2>/dev/null; fi
  return 0
}

fb_enqueue() {
  local _fb_in
  if [ ! -f "$FB_BPY" ]; then cat >/dev/null 2>&1; return 0; fi
  _fb_in="$(cat 2>/dev/null)"
  if [ -n "${AUDIT_SYNC:-}" ]; then printf '%s' "$_fb_in" | _fb_enqueue_run "$@"
  else ( printf '%s' "$_fb_in" | _fb_enqueue_run "$@" & ) 2>/dev/null; fi
  return 0
}

fb_redact() {
  local _fb_out
  if [ ! -f "$FB_BPY" ]; then printf '%s' "$2"; return 0; fi
  if _fb_out="$(printf '%s' "$2" | python3 "$FB_BPY" redact --agent "$1" 2>/dev/null)"; then
    printf '%s' "$_fb_out"
  else
    printf '[redaction failed — raw action suppressed; see audit-fallback.log]'
  fi
  return 0
}
