# RFC-0001: Lake schema

- **Status:** accepted for the four core tables, partitioning, attribution,
  build and the record columns across Claude Code, pi and opencode.
  `correction_events` (RFC-0002) is draft. The marts list is open.
- **Date:** 2026-07-06

## Summary

The normalized schema for the session lake: `sessions`, `messages`, `api_calls`,
`tool_calls` and `correction_events`, stored as Parquet partitions and exposed as
DuckDB views, fed by version-tolerant adapters with a whole build from the mirror.

## Motivation

Every downstream analysis reads these tables: cost and efficiency,
counterfactuals and priors, correction mining. The grain and the keys matter
more than any single query. Writing the schema down keeps the open parts
visible.

## Design

### Tables

One row per session, message, model call and tool invocation. Fields a runtime
does not produce are nullable.

- `sessions`: `session_id` VARCHAR, `runtime` VARCHAR, `cwd` VARCHAR, `harness`
  VARCHAR, `estate` VARCHAR, `campaign` VARCHAR (derived at build, ADR-0005;
  null off-worktree), `started_at` TIMESTAMP, `parent_session_id` VARCHAR
  (opencode only, from `session.parent_id`; ADR-0006), `cc_version` VARCHAR,
  `pi_version` VARCHAR, `oc_version` VARCHAR, `agent` VARCHAR (opencode agent,
  e.g. `explore`).
- `messages`: `message_id` VARCHAR (line uuid), `session_id`, `role`, `parent_id`
  VARCHAR (Claude Code `parentUuid`; the pi message tree), `is_sidechain`
  BOOLEAN (Claude Code only, false elsewhere), `timestamp` TIMESTAMP,
  `record_type` VARCHAR, `api_message_id` VARCHAR (provider message id, null
  for non-API rows), `origin` VARCHAR (`operator`, `tool_result` or `model`,
  structure only), `text` VARCHAR (the message's text), `interrupted` BOOLEAN
  (Claude Code only, null elsewhere).
- `api_calls`: `session_id`, `message_id` VARCHAR (representative line uuid,
  joins `messages`), `api_message_id` VARCHAR, `request_id` VARCHAR,
  `timestamp` TIMESTAMP, `model` VARCHAR, `provider` VARCHAR,
  `input`/`output`/`cache_read`/`cache_write` BIGINT, `cost_usd` DOUBLE,
  `unpriced_model` BOOLEAN. This is the ccusage `UsageEntry` grain (ADR-0006)
  and the spine of all cost analysis. `api_message_id` and `request_id` are
  null for pi and opencode, which expose neither at this grain.
- `tool_calls`: `session_id`, `message_id` VARCHAR, `tool_use_id` VARCHAR,
  `tool_name` VARCHAR, `started_at` TIMESTAMP, `ended_at` TIMESTAMP,
  `duration_ms` BIGINT, `outcome` VARCHAR (`ok`, `error`, `denied`,
  `cancelled`, `running`), `arguments` VARCHAR (JSON text), `result_text`
  VARCHAR, `mcp_server` and `mcp_tool` VARCHAR, `result_message_id` VARCHAR (the
  message carrying the result). `ended_at` and `duration_ms` are opencode only,
  the one runtime with tool timing. A Claude Code result with no matching
  `tool_use`, or a second result for one, gets its own row with a null
  `tool_name`, so every result block appears once.
- `correction_events`: RFC-0002.

Every table also carries `runtime` and `date` from the Hive partition path.

`provider` is `anthropic` for Claude Code, the pi message provider, or the
opencode `providerID`.

`sql/record.sql` is the contract: one row per column with its written meaning.
`text` is a bare string, or the text blocks joined with the two characters
backslash and n. A leading interrupt marker stays in it, and opencode includes
reasoning parts. Parsers report facts; judgment about what a message means
stays in mining. `content` and `decision` are retired.

### Grain per runtime

**Claude Code** streams one assistant turn across several JSONL lines that share
`(message.id, requestId)`, with identical input and cache counts and a growing
`output_tokens`. `api_calls` has one row per `(message.id, requestId)`, taking
`max(output_tokens)`. `<synthetic>` model rows (zero tokens) are excluded. Both
choices match ccusage.

**opencode** records rolled-up `cost` and `tokens{input,output,cache{read,write}}`
on each assistant `message` row and the same figures per step on `step-finish`
parts. Reading both would double count, so `api_calls` uses the message grain and
`step-finish` is not read. `tool_calls` come from `tool` parts.

**pi** entries carry no session id, so they link to their session by filename
(the header line holds id and cwd). The message tree is the `parent_id` chain.
Nested camelCase `usage` and `cost` are read via `CAST(message AS JSON)`. Inline
`cost.total` is preferred over the price seed; `queries/reconcile_pi_cost.sql`
reports the delta. `tool_calls` derive from `toolResult` entries. The adapter is
written to the v3 session-format spec and skips cleanly when no pi store is
present; `adapters/pi.sql` states how far it has been validated.

### Cost

Claude Code records carry no `costUSD`, so cost is computed:
`input*p_in + output*p_out + cache_read*p_cr + cache_write*p_cw` from a
versioned per-token price table (`pricing.toml` in the data home, from `adapters/pricing.example.toml`; LiteLLM rates, the table
ccusage prices from). `unpriced_model` flags a model missing from the table. The
table is the only external data; no transcript data leaves the machine.

opencode's assistant `cost` is trusted when above zero. When zero or absent, cost
is computed from the seed if the model is seeded; otherwise it stays zero and
`unpriced_model` is set. Subscription-billed models have no per-token price and
stay zero and unpriced; a computed figure for them would be wrong.

### Storage and partitioning

Parquet, zstd, partitioned `runtime=<rt>/date=<session-start-date>/part0.parquet`
under `<data_home>/lake/`. The date is the session start date, not the message
date, so every row of a session (subagent files included) lives in one partition
and a session rewrites as one deterministic unit. Day-level analytics use the
row-level `timestamp`, so a session spanning midnight is attributed to the right
day.

### Attribution (ADR-0005)

A versioned, ordered rule table owned by the user at a configured path
(`<data_home>/attribution.toml`; template
`adapters/attribution.example.toml`): `priority, cwd_glob, estate, harness,
campaign, note`. The adapter takes the lowest-priority rule whose `cwd_glob`
matches (glob `*` becomes SQL `LIKE '%'`; `coalesce(cwd,'')` so a null cwd still
hits the fallback). `harness` and `campaign` accept tokens resolved from the cwd:
`{repo}` (the directory after `gitlab.com/<ns>/` or `github.com/<ns>/`) and
`{worktree}` (the segment after `/.claude/worktrees/`, else null). The final `*`
rule is the explicit unknown bucket. The template vocabulary: `acme/*` = work,
`me-personal/*` and `github.com/*` = personal, else unknown.

Attribution (`_attr_rules` plus the token resolution) and pricing are shared
across runtimes, so they live in `sql/prelude.sql` (the views plus the
`varve_harness()` and `varve_campaign()` macros), loaded once before any adapter.

### Staging and build

Each adapter reads one runtime's mirror folder (`getvariable('mirror_dir')`) and
writes `stg_sessions`, `stg_messages`, `stg_api_calls` and `stg_tool_calls`.
`bin/build` runs one process per runtime into `lake.new`, copying each table with
`PARTITION_BY (runtime, date)` and `FILENAME_PATTERN 'part'`. A runtime that built
owns its partitions, so a table it now builds empty fails `row_counts`. A runtime
that was not built keeps its last good partitions: one whose adapter failed, one
whose mirror is empty (unless every session it published is forgotten), and one
not in `runtimes.toml`. Each published `runtime=` partition of those that
`lake.new` lacks is copied across. The checks read
`lake.new`, the lake is swapped by rename, and the mines run (ADR-0008).
`sql/prelude.sql` holds the attribution and pricing macros the adapters share.

The opencode adapter reads the mirrored `opencode.db` and its `-wal` with
`sqlite_scan`; the live store is never opened. CI proves this on a genuine SQLite WAL (rows held only in the `-wal` read back, and a read leaves the database and non-empty `-wal` unchanged); a live opencode install is still untested.

### Subagents

Claude Code writes subagent transcripts to `<session_id>/subagents/agent-*.jsonl`,
carrying the parent `sessionId` with `isSidechain=true`. The source glob must
recurse (`projects/**/*.jsonl`) or this traffic is silently dropped. Subagents
fold into their parent session; the sidechain flag lives at message grain, not as
a separate session row.

pi subagents run as `pi --no-session` children that write no transcript; the
parent records only a rolled-up usage blob. Child-session linkage is therefore
empty for pi and child API calls are not individually observable. varve does not
synthesize child rows: the cost folds into the parent rollup if pi emits one,
else it is absent. This is an accepted coverage limitation (ADR-0006).

### Content storage

Message text is stored in Parquet as `messages.text`, and tool arguments and
results as `tool_calls.arguments` and `result_text`. The lake is local-only
(ADR-0004), so keeping text costs nothing on confidentiality and lets mining run
`fts` and `vss` over it without a second fetch from source files. `sql/record.sql`
gives every column its written meaning. Correction-event pointers
(`draft_ref`, `rewrite_ref`) stay pointer-based per RFC-0002 and
invariant I5.

### Engine

No database file holds the views. `bin/duck` creates one view per lake folder
and one per data-home TOML or JSONL file at every start (ADR-0009), so the
Parquet is the only state and the engine stays disposable (ADR-0002). `just sql`
runs through the same runner. Materialized marts are deferred (see unresolved
questions).

### Reconciliation (ADR-0006)

Per-model token totals by class and computed cost reconcile against
`ccusage daily --json --mode auto`. ccusage aggregates several agents, including
Claude models seen only through other agents, so reconcile model for model
against the Claude Code model ids varve emits. See `queries/reconcile_ccusage.sql`.

### Parsers

`read_json` with an explicit `columns` list and `ignore_errors=true` tolerates schema
drift across Claude Code versions: a field that does not match its declared type
reads as NULL. This can silently drop whole files whose
column types do not reconcile, so validate file coverage (distinct filenames
read) against the on-disk count rather than assuming the glob loaded everything.

### Extensions

`vss` (vector similarity) and `fts` (full text) for mining; `sqlite` for the
opencode `ATTACH` (ADR-0006), installed and loaded by the opencode adapter at
build.

## Unresolved questions

- **Marts list.** Which materialized views are worth precomputing (burn rollups,
  cache efficiency, dispatch ratio) versus left as query-time views. All are
  query-time today; revisit once query latency is measured.
- **`correction_events` DDL** (RFC-0002). Exact column types and how the
  multi-label `divergence_category` is stored (list or join table).
- **Cache-tier pricing.** LiteLLM carries one `cache_creation_input_token_cost`;
  Claude bills 5m and 1h ephemeral creation at different rates, and the records
  expose both under `usage.cache_creation`. The single rate is used; refine if the
  reconciliation gap warrants it.

## References

- PRD sections: Architecture (lake table shapes); Goals.
- Related: ADR-0006 (normalization denominator), ADR-0005 (attribution), ADR-0001
  (transcript plane), ADR-0002 (files-first engine), RFC-0002 (correction-event
  schema).
- External: DuckDB `read_json`, `vss`, `fts`, `sqlite` extensions
  <https://duckdb.org/>.
