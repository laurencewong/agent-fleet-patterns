#!/usr/bin/env bash
# escalate.sh — example PreToolUse boundary hook for one headless agent.
#
# Wire it in the agent's .claude/settings.json:
#   "hooks": { "PreToolUse": [ { "matcher": "*", "hooks": [
#       { "type": "command", "command": ".claude/hooks/escalate.sh" } ] } ] }
#
# Runtime assumption: the agent runs headless (`claude -p`) with permission
# prompts skipped, so THIS HOOK IS THE ONLY LOAD-BEARING CONTROL. Posture is
# allow-by-default + tripwires, decided on two axes: riskclass x path-zone.
#
#   zone:  in-zone     = the agent's home dir (and any extra roots you allow)
#          self-config = the agent's own .claude/ dir and the boundary store
#          outside     = everything else
#
#   tripwires:
#     relational/outward-facing  send / post / publish / push / deploy / mutating HTTP
#     spend                      payment processors, web checkout (cap is $0)
#     irreversible/out-of-zone   rm -rf, reset --hard, writes outside the zone
#     self-config                any write to the hook, settings, or boundary store
#     opaque-write               inline interpreter code / opaque writers (see below)
#
# On a tripwire: ask the boundary store whether a grant covers this exact call
# (fb_gate). If not: DENY, park the call in the inbox (fb_enqueue), write a
# redacted stub, audit it. The agent is told to surface the need, not route
# around it. Deny + escalate, never block-and-wait (a waiting hook hangs cron).
#
# Honest limit: a PreToolUse hook sees tool_name + tool_input only. It catches
# path- and verb-shaped actions reliably; it cannot read intent.
#
# Output: PreToolUse JSON (allow|deny + reason). Requires jq + python3.

set -uo pipefail

# AGENT_HOME override exists for tests; production resolves to the real dir.
AGENT_HOME="${AGENT_HOME:-$HOME/agents/content}"
ESC_DIR="$AGENT_HOME/escalations"
LOG="$AGENT_HOME/decisions-log.md"
mkdir -p "$ESC_DIR" 2>/dev/null || true

# Colon-separated absolute roots the agent may ALSO write (e.g. a shared state
# dir it appends directives to). Empty by default.
EXTRA_ROOTS="${AGENT_EXTRA_ROOTS:-}"

INPUT="$(cat)"

allow() {
  printf '%s' "$INPUT" | fb_audit "$FB_AGENT" allow "${1:-}"
  jq -nc --arg r "${1:-}" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "allow", permissionDecisionReason: $r}}'
  exit 0
}

# deny <tripwire> <reason> <action-summary>
deny() {
  local tripwire="$1" reason="$2" action="$3" grant_rule
  if grant_rule="$(printf '%s' "$INPUT" | fb_gate "$FB_AGENT" "${tool_name:-}" "$tripwire")" \
     && [ -n "$grant_rule" ]; then
    allow "granted: $grant_rule"           # the ONLY extra allow path, grant-backed
  fi
  record_escalation "$tripwire" "$reason" "$(fb_redact "$FB_AGENT" "$action")"
  printf '%s' "$INPUT" | fb_enqueue "$FB_AGENT" "$tripwire" "$reason"
  printf '%s' "$INPUT" | fb_audit "$FB_AGENT" deny "$tripwire"
  jq -nc --arg r "BOUNDARY ($tripwire): $reason. Parked in the owner's inbox. Do not work around it; say what you need to unblock." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
      permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Human-readable stub (a rendered VIEW; the SQLite inbox is the state-holder).
# Best-effort: a logging failure must never turn into a hook crash.
record_escalation() {
  local tripwire="$1" reason="$2" action="$3" ts day slug file
  ts="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo unknown)"
  day="${ts%% *}"
  slug="$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-40)"
  [ -z "$slug" ] && slug="blocked-action"
  file="$ESC_DIR/${day}-tripwire-${slug}.md"
  if [ ! -e "$file" ]; then
    {
      printf -- '---\ntype: escalation\nauto: true\nagent: %s\ndate: %s\n---\n\n' "$FB_AGENT" "$day"
      printf -- '# Tripwire block: %s\n\n' "$tripwire"
      printf -- '- **Blocked at**: %s\n- **Reason**: %s\n- **Action (redacted)**: `%s`\n\n' "$ts" "$reason" "$action"
      printf -- 'Resolve from any surface: `inboxctl list`, then `inboxctl resolve <id> allow-once|deny --by <owner>`.\n'
    } > "$file" 2>/dev/null || true
  fi
  printf -- '\n- %s — ESCALATION [%s]: %s — action: `%s`\n' \
    "$ts" "$tripwire" "$reason" "$action" >> "$LOG" 2>/dev/null || true
}

# zone_of <path>  ->  in-zone | self-config | outside
# (heredocs live in functions, never inline in $(...): bash 3.2 can't parse that)
zone_of() {
  AGENT_HOME="$AGENT_HOME" EXTRA_ROOTS="$EXTRA_ROOTS" FB_STORE="${FLEET_BOUNDARY:-}" \
  python3 - "$1" <<'PY'
import os, sys
home = os.path.realpath(os.environ["AGENT_HOME"])
p = sys.argv[1]
if not p:
    print("in-zone"); sys.exit(0)
p = os.path.expanduser(p)
if not os.path.isabs(p):
    p = os.path.join(home, p)
rp = os.path.realpath(p)
def under(x, root):
    root = os.path.realpath(root)
    return x == root or x.startswith(root + os.sep)
self_cfg = [os.path.join(home, ".claude"), os.path.expanduser("~/.claude")]
if os.environ.get("FB_STORE"):
    self_cfg.append(os.environ["FB_STORE"])
if any(under(rp, r) for r in self_cfg):
    print("self-config"); sys.exit(0)
if rp.startswith("/dev/"):
    print("in-zone"); sys.exit(0)
for t in ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders"):
    if under(rp, t):
        print("in-zone"); sys.exit(0)
if under(rp, home):
    print("in-zone"); sys.exit(0)
roots = [r for r in os.environ.get("EXTRA_ROOTS", "").split(":") if r]
print("in-zone" if any(under(rp, r) for r in roots) else "outside")
PY
}

# write_targets <cmd>  ->  one write target per line. Only real write targets:
# redirects (> f, >> f, 2>f) and file-write verbs (tee cp mv install ln sed -i).
# Reads of absolute paths and 2>/dev/null don't count. shlex handles quoting;
# an unparseable command prints nothing (the verb tripwires still apply).
write_targets() {
  python3 - "$1" <<'PY'
import os, re, shlex, sys
try:
    toks = shlex.split(sys.argv[1], posix=True)
except ValueError:
    sys.exit(0)
verbs = {"tee", "cp", "mv", "install", "ln"}
out, i = [], 0
while i < len(toks):
    t = toks[i]
    m = re.match(r'^[0-9]*&?>>?(.*)$', t)
    if m is not None and '>' in t:
        if m.group(1):
            out.append(m.group(1))
        elif i + 1 < len(toks):
            out.append(toks[i + 1]); i += 1
        i += 1; continue
    base = os.path.basename(t)
    if base in verbs:
        rest = [x for x in toks[i+1:] if not x.startswith("-")]
        if rest:
            out.append(rest[-1])
    if base == "sed" and any(x.startswith("-i") for x in toks[i+1:i+3]):
        rest = [x for x in toks[i+1:] if not x.startswith("-") and not re.match(r'^s[/|]', x)]
        if rest:
            out.append(rest[-1])
    i += 1
print("\n".join(out))
PY
}

# --- boundary store shim ------------------------------------------------------
FB_AGENT="content"                       # the ONLY per-agent line
if [ -n "${FLEET_BOUNDARY:-}" ] && [ -r "$FLEET_BOUNDARY/hooklib.sh" ]; then
  # shellcheck source=/dev/null
  . "$FLEET_BOUNDARY/hooklib.sh"
else
  # Store absent: behave exactly like a plain deny hook. Grant nothing.
  fb_gate() { cat >/dev/null 2>&1; return 1; }
  fb_audit() { cat >/dev/null 2>&1; return 0; }
  fb_enqueue() { cat >/dev/null 2>&1; return 0; }
  fb_redact() { printf '%s' "$2"; }
fi

tool_name="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"

case "$tool_name" in
  Read|Glob|Grep|WebSearch|WebFetch|TodoWrite|Task|NotebookRead)
    allow "read-only / internal tool" ;;

  Edit|Write|MultiEdit|NotebookEdit)
    fp="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')"
    [ -z "$fp" ] && allow "no file_path"
    case "$(zone_of "$fp")" in
      in-zone)     allow "write inside the agent's zone" ;;
      self-config) deny "self-config" "write to the agent's own hook/settings or the boundary store ($fp)" "$tool_name $fp" ;;
      *)           deny "irreversible/out-of-zone" "write outside the agent's zone ($fp)" "$tool_name $fp" ;;
    esac
    ;;

  Bash)
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
    [ -z "$cmd" ] && allow "empty command"

    # --- SELF-CONFIG: an agent must never drive the approval tooling itself.
    # The ctl scripts are plain `python3 script.py` calls (which are allowed
    # below), so without this line an agent could resolve its own inbox item.
    if printf '%s' "$cmd" | grep -Eq '(^|[^a-z])(inboxctl|grantctl|boundaryctl|boundary\.py)([^a-z]|$)' \
       || { [ -n "${FLEET_BOUNDARY:-}" ] && printf '%s' "$cmd" | grep -Fq "$FLEET_BOUNDARY"; }; then
      deny "self-config" "command touches the boundary store or its approval tools" "$cmd"
    fi

    # --- RELATIONAL / OUTWARD-FACING ---
    if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push\b|--force\b|\bgh[[:space:]]+(pr|release|repo|issue)\b|\bnpm[[:space:]]+publish\b|\b(vercel|netlify|fly|heroku)\b|\bgcloud[[:space:]]+.*deploy\b|\baws[[:space:]]+.*(deploy|s3[[:space:]]+(cp|sync|rb)|ses)\b|\bsend\.sh\b|\bosascript\b.*[Mm]essage|\bmail\b|\bsendmail\b'; then
      deny "relational/outward-facing" "command publishes/sends/deploys to a third party" "$cmd"
    fi
    if printf '%s' "$cmd" | grep -Eq '\b(curl|wget|http|https)\b' \
       && printf '%s' "$cmd" | grep -Eq -- '-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--request[[:space:]]*(POST|PUT|PATCH|DELETE)|--data\b|--data-raw\b|(^|[[:space:]])-d[[:space:]]|-F[[:space:]]|--form\b' \
       && ! printf '%s' "$cmd" | grep -Eq 'localhost|127\.0\.0\.1|0\.0\.0\.0'; then
      deny "relational/outward-facing" "mutating HTTP request to a remote host" "$cmd"
    fi

    # --- SPEND ($0 cap). `git checkout` is NOT a payment checkout: that false
    # positive once blocked an ordinary branch commit.
    if printf '%s' "$cmd" | grep -Eiq '\b(stripe|paypal|braintree|chargebee)\b|\bpurchase\b'; then
      deny "spend" "command appears to move money (cap is \$0)" "$cmd"
    fi
    if printf '%s' "$cmd" | grep -Eiq '\bcheckout\b' \
       && ! printf '%s' "$cmd" | grep -Eq '\bgit[[:space:]]+(checkout|switch)\b'; then
      deny "spend" "command appears to move money (web checkout; cap is \$0)" "$cmd"
    fi

    # --- IRREVERSIBLE / DESTRUCTIVE ---
    if printf '%s' "$cmd" | grep -Eq '\brm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]|-[a-zA-Z]*[rf])|\brmdir\b|\bgit[[:space:]]+reset[[:space:]]+--hard\b|\bgit[[:space:]]+clean\b|\bdropdb\b|drop[[:space:]]+table|\bmkfs|\bdd[[:space:]]+if=|\btruncate\b|\bshred\b|(^|[;&|[:space:]]):[[:space:]]*>[[:space:]]'; then
      deny "irreversible/out-of-zone" "destructive command (delete/reset/truncate)" "$cmd"
    fi

    # --- INTERPRETER / OPAQUE-WRITE: fail CLOSED.
    # write_targets() only sees redirects + a fixed verb set. An interpreter
    # hides its write target inside a code string or stdin:
    #     python3 -c 'open(".claude/hooks/escalate.sh","w").write("...")'
    # would rewrite THIS hook, the only control on a headless agent. Arbitrary
    # code can't be parsed here, so deny inline/stdin code and opaque writers.
    # Legit forms stay open: `python3 -m mod`, `python3 script.py`,
    # `python3 --version|--help` (the bare-dash branch only matches "- " or
    # end-of-line; an earlier regex denied --version, a real false positive).
    if printf '%s' "$cmd" | grep -Eiq '(^|[^a-z])(python[0-9.]*|perl|ruby|node|deno|bun|php|osascript|rscript|lua)[[:space:]]+(-[a-z]*[ce]([^a-z]|$)|--(eval|print)([^a-z]|$)|-([[:space:]]|$)|[^|;&]*<<)'; then
      deny "opaque-write" "interpreter inline/stdin code; write target not statically parseable, fail closed" "$cmd"
    fi
    if printf '%s' "$cmd" | grep -Eiq '(^|[^a-z])(dd|truncate|rsync|patch|cpio|xxd|funzip|ex|vim|nvim)[[:space:]]|(^|[^a-z])(eval|exec|source)[[:space:]]'; then
      deny "opaque-write" "opaque file-writer / dynamic exec; write target not statically parseable, fail closed" "$cmd"
    fi

    # --- WRITES VIA SHELL (redirects / file-mutating verbs) ---
    while IFS= read -r tgt; do
      [ -z "$tgt" ] && continue
      case "$(zone_of "$tgt")" in
        self-config) deny "self-config" "shell write to the agent's own hook/settings or the boundary store ($tgt)" "$cmd" ;;
        outside)     deny "irreversible/out-of-zone" "shell write outside the agent's zone ($tgt)" "$cmd" ;;
      esac
    done <<EOF
$(write_targets "$cmd")
EOF

    allow "in-boundary bash"
    ;;

  mcp__*)
    # Outward-facing MCP tools (send/reply/post/publish) deny; so do browser
    # INTERACTION tools (typing, clicking, uploading, running page JS), which
    # can act outward even though they look "read-ish". Navigation and page
    # reads stay allowed.
    if printf '%s' "$tool_name" | grep -Eiq 'reply|send|post|publish|create_(message|post)|message$|dm\b'; then
      deny "relational/outward-facing" "MCP tool sends/posts to a third party ($tool_name)" "$tool_name"
    fi
    if printf '%s' "$tool_name" | grep -Eiq 'form_input|__computer$|javascript|file_upload|upload_image|shortcuts_execute'; then
      deny "relational/outward-facing" "browser interaction tool can execute an outward action ($tool_name)" "$tool_name"
    fi
    allow "read-ish MCP tool"
    ;;

  *)
    allow "unrecognized tool ($tool_name); no tripwire matched"
    ;;
esac
