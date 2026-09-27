# headless-runner: a reliable cron-driven `claude -p` job

Most of the fleet's daily output (digests, briefs, reminders) comes from
scheduled `claude -p` runs. Each one looks simple: fetch something, have the
model write it up, text it to a human. Getting that right unattended, every
day, took more work than the writing did. `runner.sh` is the template I ended
up with, and `examples/dev-tooling-digest/` wires it to the spotter engine in
this repo.

```
lock + same-day guard
  -> FETCH    deterministic script writes facts.md       (exit 3 = quiet day)
  -> DRAFT    claude -p, facts inlined, no tools, timeout
  -> GROUND   every number + URL in the draft must appear in facts.md
  -> SEND     deterministic transport; on failure, VERIFY at the source of truth
  -> PROMOTE  seen-state, lastsent, outbox tee (only after a confirmed send)
```

## Why each step exists

**Lock with stale-lock clearing.** launchd can fire a job while yesterday's is
still running, or after a crash left a lock behind. The lock holds a pid. If
that pid is alive the run skips. If it's dead the lock is cleared.

**Same-day guard.** launchd catches up on missed calendar intervals when the
machine wakes, so the same job can fire twice in one morning. A `lastsent` date
file makes the second run a no-op. Dry runs ignore it.

**Deterministic fetch, then the model.** The fetch step verifies everything
(counts, links, timestamps) and writes a facts file. The model only ever sees
that file, pasted into the prompt. It gets no tools, so it can't browse, can't
send, and can't pull in something unverified.

**Grounding gate.** Drafts would occasionally state a number that wasn't in the
input, like a rounded-up count or a figure recalled from training data, and
that's exactly the kind of error a reader can't catch. The prompt forbids it,
and in production that plus input restriction carried most of the load. But a
prompt is a request, not an invariant. So
`grounding_gate.py` extracts every number and URL from the draft and requires
each one to appear in the facts, after normalizing `1,232` / `1232` and
`12k` / `12000`. A draft that fails is held for review and nothing is sent.
Known hole: integers of 10 or less are allowed through, because "top 3" and
list markers are everywhere. `--small 0` closes it.

**Send is deterministic, and failure is double-checked.** The model never
sends. A shell transport does. The important lesson: **a failed send is not
proof of non-delivery.** The original transport (an AppleScript messaging
bridge) regularly returned a timeout error *after* the message had been
delivered. Retrying on that error meant the human got the same text twice. So
on any non-zero exit, the runner calls `VERIFY_CMD`, which looks for this exact
message at the source of truth (the message store, the sent-items API, the
channel history). Positive evidence means promote and don't retry. No evidence
means leave state alone and let the next run retry.

**State is promoted only after a confirmed send.** Seen-state records which
items the human has already received. If it were written before the send, a
failed send would hide those items from tomorrow's run and they'd be lost. The
order is send, then remember. A failed send leaves `lastsent`, seen-state, and
the outbox untouched.

**Outbox tee (context bridge).** Crons text the human from processes the
interactive chief-of-staff session knows nothing about. The human replies
"what's this?" and the live agent has no idea what was sent. Every successful
send is appended to an outbox file, and the live session reads it whenever the
human reacts to something it didn't send.

**Dry run and timeout.** `DRYRUN=1` runs fetch, draft, and ground, prints the
draft, and mutates nothing. The model call is wrapped in a `perl alarm`
timeout (macOS ships no coreutils `timeout`), so a hung model call can't hold
the lock forever.

**Pinned environment.** launchd starts jobs with an almost empty environment.
The runner sets PATH and a UTF-8 locale. Without the locale, one send path
silently turned em-dashes and emoji into mojibake. Every step tested clean
from a terminal, and the bug only showed up under launchd.

## Use it

```sh
# dry run the example (live fetch from HN/GitHub/RSS; needs `claude` on PATH + PyYAML)
DRYRUN=1 bash runner.sh examples/dev-tooling-digest

bash tests/runner.test.sh       # 48 cases: fake claude + fake transport, no network
```

A job is a directory with `job.conf` (`JOB_NAME`, `FETCH_CMD`, `PROMPT_FILE`,
`SEND_CMD`, and optionally `VERIFY_CMD`, `PROMOTE_CMD`, `QUIET_DAY`) plus
whatever scripts it references. Schedule it with launchd
(`examples/dev-tooling-digest/launchd.plist.example`) or cron. Set
`AUTOMATION_ID` in the job's environment so the boundary layer can tell a
scheduled run from an interactive one.
