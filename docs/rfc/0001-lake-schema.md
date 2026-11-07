# RFC-0001: Lake schema

- **Status:** accepted for the four core tables, partitioning, attribution,
  ingest and content storage across Claude Code, pi and opencode.
  `correction_events` (RFC-0002) is draft. The marts list is open.
- **Date:** 2026-07-06

## Summary

The normalized schema for the session lake: `sessions`, `messages`, `api_calls`,
`tool_calls` and `correction_events`, stored as Parquet partitions and exposed as
DuckDB views, fed by version-tolerant adapters with idempotent incremental ingest.

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
  VARCHAR, `estate` VARCHAR, `campaign` VARCHAR (derived at ingest, ADR-0005;
  null off-worktree), `started_at` TIMESTAMP, `parent_session_id` VARCHAR
  (opencode only, from `session.parent_id`; ADR-0006), `cc_version` VARCHAR,
  `pi_version` VARCHAR, `oc_version` VARCHAR, `agent` VARCHAR (opencode agent,
  e.g. `explore`).
- `messages`: `message_id` VARCHAR (line uuid), `session_id`, `role`, `parent_id`
  VARCHAR (Claude Code `parentUuid`; the pi message tree), `is_sidechain`
  BOOLEAN (Claude Code only, false elsewhere), `timestamp` TIMESTAMP,
  `record_type` VARCHAR, `api_message_id` VARCHAR (provider message id, null
  for non-API rows), `content` VARCHAR (inline JSON).
- `api_calls`: `session_id`, `message_id` VARCHAR (representative line uuid,
  joins `messages`), `api_message_id` VARCHAR, `request_id` VARCHAR,
  `timestamp` TIMESTAMP, `model` VARCHAR, `provider` VARCHAR,
  `input`/`output`/`cache_read`/`cache_write` BIGINT, `cost_usd` DOUBLE,
  `unpriced_model` BOOLEAN. This is the ccusage `UsageEntry` grain (ADR-0006)
  and the spine of all cost analysis. `api_message_id` and `request_id` are
  null for pi and opencode, which expose neither at this grain.
- `tool_calls`: `session_id`, `message_id` VARCHAR, `tool_use_id` VARCHAR,
  `tool_name` VARCHAR, `started_at` TIMESTAMP, `ended_at` TIMESTAMP,
  `duration_ms` BIGINT, `decision` VARCHAR. `ended_at` and `duration_ms` are
  opencode only, the one runtime with tool timing. `decision` is the opencode
  tool `state.status` (completed, error or running); for pi it carries an
  `isError` status when a `toolResult` reports one; null for Claude Code.
- `correction_events`: RFC-0002.

Every table also carries `runtime` and `date` from the Hive partition path.

`provider` is `anthropic` for Claude Code, the pi message provider, or the
opencode `providerID`.

`content` is inline for all three runtimes. Claude Code stores the message
content blocks and pi the message content field. opencode has no text on the
message row, so `content` is the aggregated text and reasoning `part` text.

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
versioned per-token price seed (`adapters/pricing.csv`, LiteLLM rates, the table
ccusage prices from). `unpriced_model` flags a model missing from the seed. The
seed is the only external data; no transcript data leaves the machine.

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
(`VARVE_ATTRIBUTION`, default `<data_home>/attribution.csv`; template
`adapters/attribution.example.csv`): `priority, cwd_glob, estate, harness,
campaign, note`. The adapter takes the lowest-priority rule whose `cwd_glob`
matches (glob `*` becomes SQL `LIKE '%'`; `coalesce(cwd,'')` so a null cwd still
hits the fallback). `harness` and `campaign` accept tokens resolved from the cwd:
`{repo}` (the directory after `gitlab.com/<ns>/` or `github.com/<ns>/`) and
`{worktree}` (the segment after `/.claude/worktrees/`, else null). The final `*`
rule is the explicit unknown bucket. The template vocabulary: `acme/*` = work,
`me-personal/*` and `github.com/*` = personal, else unknown.

Attribution (`_attr_rules` plus the token resolution) and pricing are shared
across runtimes, so they live in `sql/prelude.sql` (seeds plus the
`varve_harness()` and `varve_campaign()` macros), loaded once before any adapter.

### Staging

Each adapter builds `_<rt>_sessions`, `_<rt>_messages`, `_<rt>_api_calls`,
`_<rt>_tool_calls` and a `_<rt>_files` map. `sql/stage.sql` stubs any absent
runtime and unions the present ones into the `stg_*` tables the pipeline COPYs,
via `UNION ALL BY NAME`, so a column one runtime lacks is NULL for its rows. One
manifest spans all runtimes; `sql/affected.sql` keys on the unified `_files`. A
runtime whose adapter is skipped contributes no rows, so `OVERWRITE_OR_IGNORE`
leaves its existing partitions untouched.

The live opencode SQLite store (WAL) is never attached directly. The justfile
makes an APFS copy-on-write clone (`cp -c`) of `opencode.db` with its `-wal` and
`-shm` files and `ATTACH`es the clone `READ_ONLY`. Manifest change detection keys
on the live `.db` path only, since the `-wal` and `-shm` mtimes drift; a db change
marks every opencode date partition dirty, because opencode is one file.

### Incremental ingest

A per-file high-water mark, `(path, size, mtime)`, is persisted as a manifest
parquet under `<data_home>/state/`. Files that are new or whose size or mtime
changed mark their session's date partition dirty; dirty partitions are rewritten
in full from current file content, with every co-resident session re-derived.
The rewrite is deterministic, so appends to a live session's JSONL are counted
exactly once. No change means no dirty partition, no write and identical row
counts. Idempotence comes from per-partition re-derivation plus stable filenames
(`FILENAME_PATTERN 'part'` with `OVERWRITE_OR_IGNORE`), not from row-level
upserts. ingest and backfill are the sole writers; `just sql` attaches read-only
(ADR-0002, enforced by `-readonly`).

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

Message content is stored inline in Parquet. The lake is local-only (ADR-0004),
so inlining costs nothing on confidentiality and lets mining run `fts` and `vss`
over content without a second fetch from source files. Correction-event pointers
(`model_draft_ptr`, `operator_rewrite_ptr`) stay pointer-based per RFC-0002 and
invariant I5; the inline decision covers the message stream, not correction
drafts.

### Engine

DuckDB views in `<data_home>/varve.duckdb` over the Parquet, rebuildable and never
the source of truth (ADR-0002). Views use `getvariable('lake')` so `just sql`
resolves them read-only after `SET VARIABLE lake=...`. Materialized marts are
deferred (see unresolved questions).

### Reconciliation (ADR-0006)

Per-model token totals by class and computed cost reconcile against
`ccusage daily --json --mode auto`. ccusage aggregates several agents, including
Claude models seen only through other agents, so reconcile model for model
against the Claude Code model ids varve emits. See `queries/reconcile_ccusage.sql`.

### Parsers

`read_json_auto` with `union_by_name=true, ignore_errors=true` tolerates schema
drift across Claude Code versions. The pair can silently drop whole files whose
column types do not reconcile, so validate file coverage (distinct filenames
read) against the on-disk count rather than assuming the glob loaded everything.

### Extensions

`vss` (vector similarity) and `fts` (full text) for mining; `sqlite` for the
opencode `ATTACH` (ADR-0006), installed and loaded by the opencode adapter at
ingest.

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
- External: DuckDB `read_json_auto`, `vss`, `fts`, `sqlite` extensions
  <https://duckdb.org/>.
