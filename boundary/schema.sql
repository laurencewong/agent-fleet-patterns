-- Boundary store schema.
-- One SQLite DB (WAL, busy_timeout=2000) serves inbox + one-shot grants + audit.
-- Applied idempotently by `boundaryctl init` (CREATE IF NOT EXISTS only).
-- Lives OUTSIDE every agent write zone so no agent can edit its own grants.

CREATE TABLE IF NOT EXISTS inbox_items (
  id             INTEGER PRIMARY KEY,
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  agent          TEXT NOT NULL,          -- content|spotter|chief-of-staff|…
  session_id     TEXT,                   -- from hook input JSON
  automation_id  TEXT,                   -- from env AUTOMATION_ID; NULL = interactive
  tool_name      TEXT NOT NULL,
  riskclass      TEXT NOT NULL,          -- READ|WRITE_LOCAL|EXEC|EXTERNAL
  tripwire       TEXT NOT NULL,          -- hook tripwire name (fork-specific strings kept verbatim)
  reason         TEXT NOT NULL,
  resource       TEXT,                   -- extracted acted-on target (e.g. chat_id, url)
  call_hash      TEXT NOT NULL,          -- sha256("v1\n"+agent+"\n"+tool+"\n"+canonical(tool_input))
  redacted_input TEXT,                   -- redactor output, <=2KB
  stub_path      TEXT,                   -- md stub rendered for this item
  seen_count     INTEGER NOT NULL DEFAULT 1,
  last_seen_at   TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',  -- pending|resolved|expired
  resolution     TEXT,                   -- allow_once|deny|rule_proposed|noted
  resolved_by    TEXT,
  resolved_at    TEXT,
  notified_at    TEXT,                   -- pager sets; NULL = not yet paged
  consumed_at    TEXT                    -- set when a minted one-shot is used
);
-- IDEMPOTENCY: one pending item per exact call per agent.
CREATE UNIQUE INDEX IF NOT EXISTS inbox_pending_dedupe ON inbox_items(agent, call_hash)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS oneshot_grants (
  id          INTEGER PRIMARY KEY,
  minted_from INTEGER NOT NULL REFERENCES inbox_items(id),
  agent       TEXT NOT NULL,
  call_hash   TEXT NOT NULL,
  minted_by   TEXT NOT NULL,             -- enforced = OWNER at mint AND at consume
  minted_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  expires_at  TEXT NOT NULL,             -- default now+7d
  consumed_at TEXT                       -- consumption = atomic UPDATE … WHERE consumed_at IS NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS oneshot_active ON oneshot_grants(agent, call_hash)
  WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS audit_events (
  id             INTEGER PRIMARY KEY,
  ts             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  agent          TEXT NOT NULL,
  session_id     TEXT,
  automation_id  TEXT,
  tool_name      TEXT NOT NULL,
  riskclass      TEXT,
  zone           TEXT,                   -- in-zone|self-config|outside|n/a
  decision       TEXT NOT NULL,          -- allow|deny|grant_invalid|enqueue_capped
  rule           TEXT NOT NULL,          -- tripwire | 'standing:<id>' | 'oneshot:<id>' | allow-reason
  resource       TEXT,
  redacted_input TEXT,
  call_hash      TEXT,
  hook_ms        INTEGER                 -- this boundary.py invocation's own elapsed ms (added hook latency)
);
CREATE INDEX IF NOT EXISTS audit_by_agent_ts ON audit_events(agent, ts);
