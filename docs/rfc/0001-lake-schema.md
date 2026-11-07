# RFC-0001 -- Lake schema

- **Status:** accepted for Claude Code and pi + opencode (adapters built;
  opencode reconciled against its live store, pi correct-by-construction). The
  four core tables, partitioning, attribution, ingest, content-storage, and the
  pi/opencode runtime-specific fields are settled below. `correction_events`
  (RFC-0002) remains draft; the marts list stays open.
- **Date:** 2026-07-06 (revised 2026-07-06 with Claude Code then pi + opencode build results)

## Summary

The normalized schema for the transcript lake: five tables -- `sessions`, `messages`,
`api_calls`, `tool_calls`, `correction_events` -- stored as Parquet partitions and
exposed as DuckDB views and marts, fed by version-tolerant adapters with idempotent
incremental ingest. The table shapes were agreed in the PRD ("Lake table shapes"); the
data-definition-language (DDL), partitioning, and attribution-mapping representation
are now settled by the Claude Code build (Design) for the four core tables. `correction_events`
and the marts list remain open.

## Motivation

This schema is the primary output. Every downstream analysis
reads these tables: cost and efficiency, counterfactuals and priors,
correction mining (mining). Getting the grain and the keys right matters more than any
single query. The shape is settled enough to build against; the DDL is not, and
writing it down as an RFC keeps the open parts visible.

## Design

**Tables (grain -- key fields; runtime-specific fields nullable).**

- `sessions` (one row per session): `session_id`, `runtime`, `cwd`, `harness`,
  `estate`, `campaign` (derived at ingest, ADR-0005), `started_at`,
  `parent_session_id` (nullable -- empty for pi children, ADR-0006).
- `messages` (one row per message): `message_id`, `session_id`, `role`, `parent_id`
  (tree-structured for pi), `is_sidechain` (Claude Code), `timestamp`.
- `api_calls` (one row per model call): `session_id`, `message_id`, `timestamp`,
  `model`, `provider`, `input`, `output`, `cache_read`, `cache_write`, `cost_usd`.
  This is the ccusage `UsageEntry` grain (ADR-0006) and the spine of all cost analysis.
- `tool_calls` (one row per tool invocation): `session_id`, `message_id`, `tool_name`,
  `started_at`, `ended_at`, `duration_ms` (NULL except opencode), `decision` (nullable).
- `correction_events` (mining): full schema in RFC-0002.

**Resolved DDL (Claude Code).** Columns and types as built. Runtime-specific
fields are nullable so pi/opencode land without a schema break; the Claude Code build also adds a few
provenance columns (marked +) beyond the PRD shape.

- `sessions`: `session_id` VARCHAR, `runtime` VARCHAR, `cwd` VARCHAR, `harness`
  VARCHAR, `estate` VARCHAR, `campaign` VARCHAR (null off-worktree), `started_at`
  TIMESTAMP, `parent_session_id` VARCHAR (null for CC), +`cc_version` VARCHAR.
- `messages`: `message_id` VARCHAR (line uuid), `session_id`, `role`, `parent_id`
  VARCHAR (parentUuid), `is_sidechain` BOOLEAN, `timestamp` TIMESTAMP,
  +`record_type` VARCHAR, +`api_message_id` VARCHAR (provider msg id, null for
  non-API), `content` VARCHAR (**inline** JSON).
- `api_calls`: `session_id`, `message_id` VARCHAR (representative line uuid,
  joins `messages`), +`api_message_id` VARCHAR, +`request_id` VARCHAR, `timestamp`
  TIMESTAMP, `model` VARCHAR, `provider` VARCHAR, `input`/`output`/`cache_read`/
  `cache_write` BIGINT, `cost_usd` DOUBLE, +`unpriced_model` BOOLEAN.
- `tool_calls`: `session_id`, `message_id` VARCHAR, +`tool_use_id` VARCHAR,
  `tool_name` VARCHAR, `started_at` TIMESTAMP, `ended_at` TIMESTAMP (null CC),
  `duration_ms` BIGINT (null CC), `decision` VARCHAR (null CC).

Every table also carries `runtime` and `date` via the Hive partition path.

**Runtime-specific nullable columns (resolved).** pi and opencode land as
additional `runtime=` partitions with the same core columns; their extra columns
are unioned in via `UNION ALL BY NAME` (sql/stage.sql), so a column a runtime does
not produce is simply NULL for that runtime's rows -- the nullable-fields contract.

- `sessions`: +`pi_version` VARCHAR (pi header version, null off-pi), +`oc_version`
  VARCHAR (opencode session version), +`agent` VARCHAR (opencode agent, e.g.
  `explore`). `parent_session_id` -- **null for Claude Code and pi**, **populated
  for opencode** (opencode chains sessions via `session.parent_id`; 1318/1626
  observed). `cc_version` null off-CC.
- `api_calls`: unchanged shape. `provider` is `anthropic` (CC), the pi message
  provider, or the opencode `providerID` (`anthropic`/`gitlab`/`openai`/`google`/
  `google-vertex` observed). `api_message_id`/`request_id` null for pi + opencode
  (neither exposes a provider message/request id at this grain).
- `tool_calls`: `ended_at`/`duration_ms`/`decision` -- **null for CC and pi**,
  **populated for opencode** (the only runtime with tool start/end timing:
  `duration_ms` on 89671/89684 tool parts; `decision` = opencode tool `state.status`
  {completed|error|running}). pi's `decision` carries only an `isError` status when
  a toolResult reports one.
- `messages`: `content` inline for all three. CC stores the message content blocks;
  opencode has no text on the message row, so `content` is the aggregated text +
  reasoning `part` text (RFC content-inline decision honored per runtime); pi stores
  the message content field. `is_sidechain` is CC-only (false for pi/opencode --
  pi branches via the `parent_id` tree, opencode chains via session `parent_id`).

**api_calls grain / dedup (resolved).** Claude Code streams one assistant turn
across several JSONL lines that share `(message.id, requestId)` with identical
input/cache but a growing `output_tokens`; the final line holds the complete usage.
One `api_calls` row per `(message.id, requestId)`, taking `max(output_tokens)`
(input/cache are constant, so `max` == the value). `<synthetic>` model rows (zero
tokens) are excluded -- both choices match ccusage and reconcile to it.

**Cost (resolved).** `costUSD` is absent from every record in the current corpus,
so cost is always computed: `input*p_in + output*p_out + cache_read*p_cr +
cache_write*p_cw` using a versioned per-token price seed (`adapters/pricing.csv`,
LiteLLM rates -- the table ccusage prices from). `unpriced_model` flags any model
missing from the seed (currently none). Pricing metadata only; no transcript data
leaves the machine to obtain it.

**Storage / partitioning (resolved).** Parquet, zstd, partitioned
`runtime=<rt>/date=<session-start-date>/part0.parquet` under `<data_home>/lake/`.
**Date is the session START date, not the message date.** Rationale: it keeps every
row of a session in one partition, so a session (and its subagent files) rewrites as
one deterministic partition unit -- the basis of idempotent incremental ingest.
Day-level analytics use the row-level `timestamp` column, not the partition key, so a
session spanning midnight is still attributed to the right day. Cardinality validated
on the full corpus: 31 distinct dates over ~2 months -- low, no high-cardinality risk.

**Attribution mapping (resolved, ADR-0005).** A versioned, ordered rule table
(operator data at a configured path -- `VARVE_ATTRIBUTION`, default
`<data_home>/attribution.csv`; format template `adapters/attribution.example.csv`;
relocated out of the repo 2026-07-06, public-instrument rule): `priority, cwd_glob,
estate, harness, campaign, note`.
The adapter takes the lowest-priority rule whose `cwd_glob` matches (glob `*` ->
SQL `LIKE '%'`; `coalesce(cwd,'')` so a null cwd still hits the fallback). `harness`
and `campaign` support structural tokens resolved from the cwd: `{repo}` (the repo
dir after `gitlab.com/<ns>/` or `github.com/<ns>/`) and `{worktree}` (the segment
after `/.claude/worktrees/`, else null). The final `*` rule is the explicit unknown
bucket. Seeded with the estate layout (template vocabulary): `acme/*` = work,
`me-personal/*` + `github.com/*` = personal, else unknown.

**Incremental ingest / late-arriving appends (resolved).** A per-file high-water
mark -- `(path, size, mtime)` -- is persisted as a manifest parquet under
`<data_home>/state/`. On ingest, files whose size or mtime changed (or are new) mark
their session's date partition dirty; those partitions are rewritten in full from the
current file content (all co-resident sessions re-derived), which is deterministic, so
Claude Code's appends to the live session's JSONL are counted exactly once. No change
-> no dirty partition -> no write -> identical row counts. Idempotence therefore comes
from deterministic per-partition re-derivation plus stable filenames
(`FILENAME_PATTERN 'part'` + `OVERWRITE_OR_IGNORE`), not from row-level upserts.
Single writer: ingest/backfill are the sole writers; `just sql` attaches read-only
(ADR-0002, enforced by `-readonly`).

**Subagent traffic (resolved).** Newer Claude Code writes subagent transcripts to
`<session_id>/subagents/agent-*.jsonl`, nested a level deeper and carrying the parent
`sessionId` with `isSidechain=true`. The source glob MUST recurse (`projects/**/
*.jsonl`) or this traffic (the majority of files) is silently dropped. Subagents fold
into their parent session; the sidechain flag lives at message grain, not as a
separate session row.

**Content storage (resolved).** Message content is stored **inline** in Parquet.
The lake is local-only (ADR-0004), so inlining costs nothing on confidentiality and
enables mining `fts`/`vss` over content without a second fetch from source JSONL.
Correction-event pointers (`model_draft_ptr`, `operator_rewrite_ptr`) stay
pointer-based per RFC-0002 / invariant I5 -- the inline decision applies to the
message stream, not to correction drafts.

**Engine layer.** DuckDB views in `<data_home>/varve.duckdb` over the Parquet,
rebuildable and never the source of truth (ADR-0002). Views use `getvariable('lake')`
so `just sql` resolves them read-only after `SET VARIABLE lake=...`. Materialized
marts: deferred (see open questions).

**Reconciliation (resolved gate, ADR-0006).** Per-model token totals by class and
computed cost reconcile against `ccusage daily --json --mode auto`. Note ccusage v20
is a multi-agent aggregator (it also reports opencode/codex/gemini and other agents, and
Claude models seen only through other agents), so reconcile model-for-model against
the Claude Code model ids varve emits. Stated tolerance and measured deltas: see the
build report and `queries/reconcile_ccusage.sql`.

**Parsers.** `read_json_auto` with `union_by_name=true, ignore_errors=true` tolerates
schema drift across CC versions (2.1.114 .. 2.1.201 observed). Note: `ignore_errors`
plus `union_by_name` can silently drop whole files whose column types do not
reconcile -- validate file coverage (distinct filenames read) against the on-disk
count, do not assume the glob loaded everything.

**Extensions.** `vss` (vector similarity) and `fts` (full-text) for mining; `sqlite` for
the opencode `ATTACH` (ADR-0006). `sqlite` is `INSTALL`ed/`LOAD`ed by the opencode
adapter at ingest.

## pi + opencode build results -- decisions the new runtimes forced

**Shared adapter prelude.** Attribution (`_attr_rules` + the `{repo}`/`{worktree}`
token resolution) and pricing are identical across runtimes, so they moved to
`sql/prelude.sql` (seeds + `varve_harness()`/`varve_campaign()` macros) loaded once
before any adapter. The Claude Code adapter was refactored onto the macros; a
frozen-source A/B proved the refactor byte-identical (row counts per table and
priced totals identical to the cent, OLD == NEW).

**Per-runtime staging, unioned.** Each adapter builds `_<rt>_sessions/_messages/
_api_calls/_tool_calls` + a `_<rt>_files` map; `sql/stage.sql` stubs any absent
runtime and unions all present ones into the `stg_*` the pipeline COPYs, via
`UNION ALL BY NAME` (the column-superset mechanism for nullable runtime fields).
One manifest spans all runtimes; `sql/affected.sql` keys on the unified `_files`.
A runtime whose adapter is skipped contributes no rows, so `OVERWRITE_OR_IGNORE`
leaves its existing partitions untouched.

**opencode api_calls grain = one assistant message.** opencode records per-message
rolled-up `cost` + `tokens{input,output,cache{read,write}}` on the assistant
`message` row, and ALSO per-step figures on `step-finish` `part`s. Reading both
would double-count, so api_calls uses the message grain (the authoritative
rollup); step-finish is not read. tool_calls come from `tool` `part`s (the only
tool timing anywhere).

**opencode cost:0 defense.** Assistant `cost` is trusted when > 0. When 0/absent:
compute from the pricing seed if the model is seeded; else keep 0 and flag
`unpriced_model`. Most cost:0 rows are subscription-billed models with no
per-token price -- fabricating a per-token cost for them would be wrong, so they
stay 0 + unpriced. The seed was extended with the opencode-only Anthropic Opus
versions (`claude-opus-4-6`/`4-5`, Opus-tier rate) so the defense recomputes their
true-zero rows -- which resolve to \$0 because those turns carry zero billable
tokens (correct, not under-counted). Inline-priced calls reconciled
(Anthropic/OpenAI/Google); unpriced calls are subscription-billed models plus
non-seeded providers with inline cost.

**opencode read is provably non-destructive.** The live SQLite store (WAL)
is never attached directly. The justfile makes an APFS copy-on-write clone
(`cp -c`, ~5 ms, no extra space) of `opencode.db` (+ `-wal`/`-shm`) and `ATTACH`es
the clone `READ_ONLY`; the live `opencode.db` is byte-identical (sha256, size,
mtime) before/after every run. Only the ephemeral `-shm` mtime drifts, externally
to varve. Manifest change-detection keys on the live `.db` path only (the `-wal`/
`-shm` mtimes drift and would trigger false rebuilds); a db change marks all
opencode date partitions dirty (opencode is one file).

**pi built correct-by-construction, unvalidated.** There is NO pi install on the
build machine, so the pi adapter (written to the v3 session-format spec) is
UNVALIDATED against real files and is a clean skip (exit 0) here. Decisions baked
in for when a pi corpus appears: entries carry no sessionId, so they link to their
session by FILENAME (the header line holds id + cwd); the message tree is the
`parent_id` chain (`is_sidechain` false); nested camelCase `usage`/`cost` are read
via `CAST(message AS JSON)` to avoid struct-casing loss; inline `cost.total` is
preferred over the seed (reconciliation delta is query-time,
`queries/reconcile_pi_cost.sql`); tool_calls derive from `toolResult` entries.

**pi subagent coverage hole (upstream gap, do not fabricate).** pi subagents spawn
`pi --no-session` children that write NO transcript; the parent records only a
rolled-up usage blob. Child-session linkage is therefore empty for pi and those
child API calls are not individually observable. varve does not synthesize child
rows -- the subagent cost folds into the parent rollup if pi emits one, else it is
absent. This is a known, accepted coverage limitation (ADR-0006), distinct from
Claude Code, whose subagents DO write transcripts (`<session>/subagents/`).

**Attribution surfaces estates outside the current seed (coordinator judgment).**
opencode session cwds include work paths the Claude Code seed does not name -- historical
work checkouts that predate the current namespace layout -- which currently route
to the `unknown` bucket. Extending the attribution rule file is an estate-taxonomy
call left to the coordinator; the adapter reuses the existing rules unchanged.

## Unresolved questions

Resolved by the Claude Code build (see Design): DDL and column types; partition cut (session
start date) and cardinality; attribution mapping representation and fallback;
appended-session delta handling; message-content storage (inline). Still open:

- **Marts list.** Which materialized views are worth precomputing (e.g. burn rollups,
  cache-efficiency, dispatch ratio) vs left as query-time views. Left as query-time
  views in the Claude Code build; revisit when the query library exists and query latency is measured.
- **`correction_events` DDL** (RFC-0002). The mining table's exact column types and how the
  multi-label `divergence_category` is stored (list vs join table) -- deferred to mining.
- ~~**pi / opencode runtime fields.**~~ **Resolved (see pi + opencode build results
  above).** opencode populates `parent_session_id`, `duration_ms`/`ended_at`/
  `decision`, `oc_version`, `agent`, and provider variety; pi populates `pi_version`
  and the `parent_id` message tree. All land as nullable superset columns via
  `UNION ALL BY NAME`. pi's shapes are spec-derived (no local corpus to validate).
- **Cache-tier pricing.** LiteLLM carries one `cache_creation_input_token_cost`; Claude
  bills 5m vs 1h ephemeral creation at different rates (the records expose both under
  `usage.cache_creation`). The Claude Code build uses the single rate; refine if the reconciliation gap
  warrants it.

## References

- PRD sections: Architecture (lake table shapes); Goals.
- Related: ADR-0006 (normalization denominator), ADR-0005 (attribution), ADR-0001
  (transcript plane), ADR-0002 (files-first engine), RFC-0002 (correction-event schema).
- External: DuckDB `read_json_auto`, `vss`, `fts`, `sqlite` extensions
  <https://duckdb.org/>.
