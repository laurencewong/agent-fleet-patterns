# dispatcher: keep the live agent answering

The chief-of-staff agent is the one I text. It also used to do the work I
texted it about. On a busy day that meant it went quiet for hours while it
debugged a browser upload or scraped flight prices, and messages piled up
behind the job. Nothing was broken. It was just doing one long thing at a
time, in the one session that was supposed to stay reachable.

The fix is to treat the live session as a dispatcher. It answers, hands off,
tracks, and reports. Workers do the long work somewhere else.

```
message in
  -> RECEIPT    within ~1 min: "Got it: <plan>, ~<ETA>"
  -> DECIDE     under ~2 min? answer inline. Otherwise:
  -> CAPACITY   capacity.sh: window full? queue it for tonight instead
  -> DISPATCH   background worker (a fork if it needs context, a specialist if not)
  -> BOARD      one row per worker: task, worker, started, ETA, status
  -> VERIFY     worker finishes; check the output before trusting it
  -> REPORT     one consolidated message per result

outside the model, every 5 min:
  reply-watchdog.sh: newest message unanswered for 15 min? alert the human
```

## The pieces

**The rule.** This one lives in the agent's instructions. Send a receipt line
first. Answer inline only if it takes under about two minutes, and send
anything longer to a background worker. Independent pieces go out in
parallel. If the live session has to do something long itself, it sends the
ETA before starting.

**[`dispatch-board.template.md`](dispatch-board.template.md).** A plain
markdown table the live session keeps current. Its main job is to survive
context loss. When the conversation gets summarized or the session restarts,
the board says what is still out and who owes a result. It also answers
"what are you working on" without guessing.

**[`capacity.sh`](capacity.sh).** One line, cheap enough to run before every
dispatch:

```
window=7% resets_in=256m state=ok
```

It reads the current 5-hour usage block from
[ccusage](https://github.com/ryoppippi/ccusage). Above the tight threshold,
non-urgent work goes to an overnight backlog instead of a new worker, so the
live session keeps enough room to answer.

**[`reply-watchdog.sh`](reply-watchdog.sh).** The rule above is a prompt, and
prompts fail in exactly the situation they're meant for. A session stuck in a
long call, or out of quota, can't notice that it's ignoring someone. So the
check lives outside the model. Every 5 minutes launchd runs a shell script
that reads the Messages database read-only. If the owner's newest message in
a watched chat is more than 15 minutes old and nothing has gone back in that
chat since, it sends one alert, with the capacity line attached so the human
can tell "busy" from "out of quota". It alerts once per message. A failed
send isn't marked, so the next tick retries.

## What broke

- **About four hours of silence.** The live session took on several long
  jobs in a row, each reasonable on its own. There was no rule that said
  "hand this off", and nothing outside the session noticed the gap. A
  time-sensitive question got answered after it stopped mattering.
- **Usage-limit stalls.** Twice in the same day the 5-hour window ran out
  mid-task. Workers launched from the live session draw on the same quota, so
  dispatching more work made the stall more likely. The capacity check is
  the brake on that.
- **The usage alert was wrong about time.** ccusage reports `endTime` in UTC.
  An earlier alert script parsed it as local time and told me the window
  reset hours later than it did. `capacity.sh` parses it as UTC, and the test
  suite checks the reset minutes against a known end time.
- **Piping ccusage into jq truncated the JSON** on some runs. Writing to a
  temp file first, then parsing, fixed it.
- **Receipts that depended on UI automation.** The first receipt was a
  tapback reaction, which needs Accessibility permission. The background host
  didn't have it, so the receipts silently never appeared. A plain text line
  works everywhere.

## Setup

```sh
cp dispatcher/watchdog.conf.example dispatcher/watchdog.conf   # fill in
WATCHDOG_CONF=dispatcher/watchdog.conf bash dispatcher/reply-watchdog.sh --dry-run
cp dispatcher/launchd.plist.example ~/Library/LaunchAgents/com.example.reply-watchdog.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.reply-watchdog.plist
```

The watchdog needs Full Disk Access for whatever runs it (it reads
`~/Library/Messages/chat.db`). `SEND_CMD` is any script that reads a message
on stdin and sends it to the chat ID in `$1`. Set `LANG`/`LC_ALL` in the
plist: launchd starts with an empty locale and the emoji arrives garbled.

## Tests

```sh
bash dispatcher/tests/dispatcher.test.sh   # 25 cases
```

They use saved ccusage JSON, a throwaway SQLite file shaped like chat.db, and
a fake send script.
