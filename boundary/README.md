# boundary: a governed-agent boundary for headless Claude Code

Every agent in the fleet runs `claude -p` from a cron with permission prompts
skipped. Nobody is watching the terminal. So the only thing standing between a
model and `git push --force`, a text to the wrong person, or a rewrite of its
own guardrails is a PreToolUse hook. This directory is that hook layer and the
small store behind it.

## Pieces

| file | role |
|---|---|
| `examples/escalate.sh` | the enforcer: one per agent, bash 3.2, emits allow/deny JSON |
| `hooklib.sh` | four functions the hook sources: `fb_gate`, `fb_audit`, `fb_enqueue`, `fb_redact` |
| `boundary.py` | stdlib-only helper: classify, hash, redact, audit, enqueue, gate, inbox, grants |
| `schema.sql` | SQLite (WAL): `inbox_items`, `oneshot_grants`, `audit_events` |
| `riskclass.tsv` | tool to riskclass map (READ / WRITE_LOCAL / EXEC / EXTERNAL) + the arg that names the target |
| `bin/inboxctl` `bin/grantctl` `bin/boundaryctl` | human-side CLIs |

## How a tool call is decided

```
tool call -> escalate.sh
  classify: riskclass (declared per tool; Bash is classified by content)
            zone      (in-zone | self-config | outside)
  no tripwire  -> audit allow (async) -> allow
  tripwire     -> fb_gate: does a grant cover this exact call?
                   1. one-shot grant for this call hash, unconsumed, unexpired -> consume, allow
                   2. standing grant: EXTERNAL tool, exact target, matching cron id -> allow
                   3. otherwise: enqueue to inbox (dedupe) + redacted stub + audit -> deny
```

The hook never blocks and waits for a human. A waiting hook hangs a cron run.
It denies, tells the agent to say what it needs, and parks the exact call in
the inbox. When the human approves from their phone ("allow 107"), that mints a
**one-shot grant** bound to the SHA-256 of `agent + tool + canonical(tool_input)`.
The agent's next run retries the identical call, the hook consumes the grant
atomically, and the call goes through once. Any change to the input is a
different hash and is denied again.

## Properties the tests pin down

- **Fail toward blocking.** If `boundary.py`, the DB, or the whole store is
  missing, grants read as "none" and every deny stands. Audit and enqueue
  failures fall back to a flat log and exit 0; they can never crash or stall a
  tool call. No code path turns a deny into an allow except a valid grant.
- **Idempotent inbox.** A partial unique index allows one pending row per
  (agent, call_hash). Twenty parallel identical denies produce one row with
  `seen_count = 20`.
- **First responder wins.** Resolution is `UPDATE ... WHERE status='pending'`.
  Twenty parallel resolvers produce exactly one winner, and the losers are told
  who won. Two parallel retries consume a one-shot exactly once.
- **Only the owner mints.** `allow-once` requires `--by <OWNER>`. Standing
  grants need `ratified_by=<OWNER>`, an expiry, an EXTERNAL tool with a declared
  target arg, and the matching `AUTOMATION_ID` (so they fire only inside the
  approved cron, never interactively). Invalid rows are ignored and audited as
  `grant_invalid`. They are never partially honored.
- **Never grantable.** `self-config` and `spend` tripwires, and any call whose
  input points into the store itself. Standing grants never cover `Bash` or
  local writes.
- **Redaction.** Token-shaped literals (`sk-`, `ghp_`, `xox*-`, `AKIA`, JWTs,
  PEM blocks), secret-named keys and flags, and message bodies past 48 chars are
  masked before anything reaches the audit row or the markdown stub. Capped at
  2 KB, and idempotent.
- **Out of reach.** The store lives outside every agent's write zone, and the
  hook denies writes to it, to the agent's own `.claude/`, and any command
  that invokes the approval tools.

## The interpreter bypass

The first version of the hook parsed shell writes (redirects, `cp`, `tee`,
`sed -i`) and checked their targets against the agent's zone. That holds up
until the agent writes:

```sh
python3 -c 'open(".claude/hooks/escalate.sh","w").write("exit 0")'
```

The write target is inside a code string, so the parser never sees it. The
same is true of heredocs, `perl -e`, `node --eval`, `dd`, `rsync`, `patch`,
`eval`, and `source`. You can't statically analyze arbitrary code in a bash
hook, so the fix is to **fail closed**: deny inline or stdin interpreter code
and opaque writers as `opaque-write`, and leave `python3 script.py`,
`python3 -m mod`, and `--version` open. The first regex also denied
`python3 --version`, and that false positive is now a regression test.

A second hole of the same kind: `inboxctl` is just `python3 script`, which is
allowed. Without an explicit `self-config` rule, an agent could resolve its own
inbox item. The example hook denies any command that names the approval tools
or the store path.

## Two bugs worth knowing about

- **Backgrounded readers see empty stdin.** Audit writes run in the background
  so they add no latency. In bash without job control, a `&` command gets an
  implicit `</dev/null`, so every async audit row recorded `tool_name='?'`.
  About 1,700 blind rows piled up before anyone noticed. The fix is to capture
  stdin first and pipe it into the background job (see `hooklib.sh`).
- **Regex tripwires have false positives, and they cost trust.** `checkout`
  meant "web checkout" (spend) until it blocked a `git checkout -b`. Each false
  positive gets a test case.

## Run it

```sh
export FLEET_BOUNDARY="$HOME/.agent-boundary"      # outside every agent's write zone; not synced storage
mkdir -p "$FLEET_BOUNDARY" && cp boundary.py hooklib.sh schema.sql riskclass.tsv "$FLEET_BOUNDARY/"
cp -R bin "$FLEET_BOUNDARY/" && "$FLEET_BOUNDARY/bin/boundaryctl" init
cp examples/escalate.sh "$HOME/agents/content/.claude/hooks/"   # set FB_AGENT + AGENT_HOME

bash tests/boundary.test.sh    # 96 cases: redaction, hashing, inbox races, grant matrix, fail-closed
bash tests/hook.test.sh        # 59 cases: real hook + temp store, full deny -> approve -> retry loop
```

Standing grant row format (`grants.d/<agent>.tsv`, tab-separated, git-versioned):

```
grant_id  automation_id  tool                                  target_arg  target_value  expires     ratified_by  ratified_on  note
g-0001    morning-brief  mcp__plugin_imessage_imessage__reply  chat_id     <self-chat>   2026-12-31  owner        2026-07-24   cron -> owner only
```

Threat model: this defends against model-driven tool calls, not against the OS
user. `--by owner` is an asserted identity. What actually protects it is that
agents can't reach the tools (see self-config above). The phone relay that
turns "allow 107" into a resolve only accepts messages from the owner's own
handle.
