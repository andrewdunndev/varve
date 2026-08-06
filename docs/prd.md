# varve -- Product Requirements Document (PRD)

*varve (n.): one annual sediment layer in a glacial lake; read in sequence, varves reconstruct history. This instrument accumulates readable layers of an agent estate's session records and mines them for signal.*

**Status:** decided (architecture settled; the lake DDL settled with the W2 build, RFC-0001; presentation layer and stage gates remain open).
**Pivoted 2026-07-06** from ClickStack/ClickHouse to Parquet + DuckDB after an operator challenge to the engine preselection; the server-shaped stack is deferred to the team/always-on stage (see Pivot record, ADR-0002).
**Scope:** local, single-operator, MacBook. **Repo:** `gitlab.com/dunn.dev/varve` -- a public instrument; operator-specific rules, names, and readings live outside the repo (the data home), and estate/client identifiers never appear in committed artifacts.
**Driven by:** the observability campaign in the work harness.
**Supersedes:** the O1-O6 sketch in that campaign's brief (mapping in Workstreams). This PRD is the source of truth where the two disagree.
**Decision records:** settled choices are captured as architecture decision records (ADRs, `docs/adr/`); open designs as requests for comment (RFCs, `docs/rfc/`). Cross-referenced throughout.

## Summary (read in 10 seconds)

Build a local session-record lake, not a dashboard -- and the lake is **files, not a server**. Per-runtime adapters normalize on-disk session records into [Apache Parquet](https://parquet.apache.org/) partitions under `~/.local/share/varve/`; [DuckDB](https://duckdb.org/) (a single mise-pinned binary) queries them in place. **Zero resident processes, no listeners, nothing bound -- not even localhost.** The canonical artifact is the Parquet + schema + versioned SQL query library; the engine is disposable. Empirical basis: the operator's entire transcript history is 774 MB across 782 files, and DuckDB aggregates it in seconds -- 3-4 orders of magnitude below ClickHouse's design point. ClickHouse/ClickStack is not rejected, just deferred to the stage that needs always-on/multi-writer/multi-user (the team stage or the x86 box); it reads Parquet natively, so the lake ports directly. The live OpenTelemetry (OTel) counts plane is deferred too -- transcripts are canonical and the concept must be proven first. The lake serves a goal ladder: table-stakes cost optimization, harness-tuning adequacy ("does a `no` land once and hold, or am I re-litigating it"), a far-stretch team-level post-training decision instrument, and -- supporting all of it -- historic-record simulation with leak-free benchmark synthesis.

## Decisions made (read in 30 seconds)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Center of gravity | **Session-record lake first, observability second** | The operator's own reframe: mine transcripts, don't just watch metrics. Runtime-agnostic; enables historical backfill; a runtime with no telemetry still gets full coverage. *(ADR-0001)* |
| D2 | Engine | **Parquet lake + DuckDB (v1); files canonical, engines disposable.** ClickStack deferred to team/always-on stage | Scale mismatch: 774 MB / ~56K API calls of total history is 3-4 orders below ClickHouse's design point; DuckDB aggregates it in seconds. Parquet ports to ClickHouse natively when a server is actually needed. *(ADR-0002)* |
| D3 | Runtime | **No container runtime in v1; mise-pinned binaries.** Apple `container` deferred until a server-shaped component exists | Prove the concept before adding runtime overhead. A single-binary DuckDB has no container, LaunchAgent, volume, or vmnet surface to manage. *(ADR-0002)* |
| D4 | Retention | **Keep everything.** No TTL cull, no hard cap. Disk watch/alert at ~100 GB (nearly moot) | The historic record is the asset. zstd-compressed Parquet makes keep-everything trivial at this scale; the disk watch stays as a cheap tripwire. *(ADR-0003)* |
| D5 | Attribution | **Ingest-time cwd→estate/campaign mapping is primary**; session-manager env injection secondary | The transcript mapping is deterministic, retroactive, and works for backfill -- so the session-manager feature is not a blocker. *(ADR-0005)* |
| D6 | Team side quest | **Private-first, abstract later** | Prove the signal on the operator; the team deliverable is a role-level method write-up + reference config extracted after it works. No day-1 shareability constraint. Abstraction ladder: n-of-1 → team conventions → post-training decision instrument (G3). *(ladder in RFC-0004 §d)* |
| D7 | Content posture | **Content enters the lake only via transcript ingest, local-only.** No listener at all in v1 (no server, no OTLP endpoint) | Confidentiality strictly improves vs the old two-plane design: nothing is bound, so there is no ingest surface to secure. Content is exactly what already sits in `~/.claude`; the lake makes it queryable without changing its exposure. *(ADR-0004)* |
| D8 | Deployment | **MacBook local for this scope**; lake must later port to an x86 Linux server | Portability is a constraint on config, not a deliverable here. Parquet + SQL port unchanged; the engine swaps to ClickHouse at that stage. *(ADR-0002; re-entry in RFC-0004 §b)* |
| D9 | Live counts plane | **Deferred.** No OTLP wiring in v1 | Not needed to prove the concept; transcripts are canonical and telemetry loss was already declared acceptable. Later option documented in W3. *(RFC-0004 §a)* |

## Goals (a ladder)

1. **Table stakes (G1) -- efficiency wins from history.** Find opportunities -- behavior, harness, skills -- to cut spend and token burn. Concrete: re-price historic dispatches under other models; measure dispatch ratios, cache efficiency, where sessions go long.
2. **Stretch (G2) -- harness-tuning adequacy.** Am I tuning the harness enough? Do I re-litigate the same decisions too much? The operational signal is recurrence: the same correction or instruction issued across sessions means context belongs in the harness, and the durability test measures whether baking it in made the recurrence stop. Count-level proxies live in W5; the content-level analysis is W7's correction/re-litigation mining.
3. **Far stretch (G3) -- team-level post-training decision instrument.** Detect, at team level, codified preference drift from baseline model training with enough confidence to justify going beyond context engineering into post-training for a specific effort -- shaped as a lightweight service at the scope of a group or project. The measurable criterion: divergence mass that is large, consistent, and durability-resistant (categories where distilled rules repeatedly fail to hold are the post-training candidates). This scope builds the n-of-1 instrument that produces exactly those measurements; the service itself is out of scope (D6 ladder, W7 stage 3).
4. **Supporting (G4) -- historic record → simulation.** Use the record as decision evidence for harness design, in three staged shapes: cost counterfactuals, design priors, and (later, go/no-go) a replay rig -- plus workload abstraction for a benchmark system that never leaks real work.

## Architecture (read in 60 seconds)

```
  Runtimes (on-disk records)        Ingest (just / cron)          Lake (files) + engine (disposable)
  --------------------------        --------------------          ----------------------------------
  Claude Code  ~/.claude/*.jsonl ─┐                               Parquet partitions
  pi           ~/.pi/*.jsonl     ─┼─ transcript adapters ──────▶  ~/.local/share/varve/lake/runtime=*/date=*/*.parquet
  opencode     opencode.db       ─┘  (cwd→estate mapping,                     │
                                      version-tolerant)                       ▼
                                                                 DuckDB views / marts (~/.local/share/varve/varve.duckdb)
                                                                             │
                                                                             ▼
                                                                 SQL query library / notebooks / reports

  No server. No container runtime. No listener of any kind. Zero resident processes. Zero egress.
```

**Transcript plane (primary, canonical, runtime-agnostic -- the only plane in v1).** Per-runtime adapters read each runtime's on-disk session records and normalize into shared-schema Parquet partitions; DuckDB attaches views/marts over them. Full content, local-only. Serves G2, G3, and G4; enables backfill from existing transcripts. The empirically-validated common denominator is [ccusage](https://github.com/ryoppippi/ccusage)'s `UsageEntry` (session_id, timestamp, model, provider, usage{input, output, cache_read, cache_write}, cost_usd) -- universal across all three runtimes at per-API-call granularity. Runtime-specific fields are nullable.

**Live counts plane -- deferred (see W3; full deferred design RFC-0004 §a).** Would carry OTel metrics/events over OpenTelemetry Protocol (OTLP), counts-only. Not wired in v1: transcripts are canonical and telemetry loss is acceptable. The counts-only invariant text is retained (I1) for whenever it wakes.

**What changed from the campaign sketch:** the store is files, not a database server. Full content DOES enter the lake -- via transcript ingestion into local Parquet, not telemetry. The content is what already lives in `~/.claude` on this disk; the lake makes it queryable without changing its exposure (same machine, same user, and now not even a localhost listener).

### Confidentiality invariants (load-bearing -- client confidentiality + the operator's estates)

These do not change across any workstream. If a design choice conflicts with one, the invariant wins. *(Recorded as ADR-0004.)*

- **I1.** (Dormant in v1, retained.) If a telemetry plane is ever wired, every `OTEL_LOG_*` content flag stays OFF and the pipe carries counts + metadata only.
- **I2.** Content enters the system only via the transcript plane, only into the local Parquet lake, only from files already on this disk.
- **I3.** No listeners in v1. Zero egress. No cloud/SaaS backend. Any future listener (team stage) binds `127.0.0.1`.
- **I4.** The operator's private estates are never named in any committed or published artifact -- estate and client identifiers live outside the repo, in the data home; W6-v2 synthetic benchmarks and any W7 publication are role-level abstractions with no sector, account, research, or estate identifiers.
- **I5.** Correction-event content (model drafts, operator rewrites) is stored as local-only pointers (`model_draft_ptr`, `operator_rewrite_ptr`); it never rides the OTel pipe and is never published verbatim.

## Non-goals

- No cloud/SaaS backend. No egress. Nothing leaves this machine.
- No server, no container runtime, no listener in v1. No always-on process.
- No team deployment in this scope. The x86 Linux server is a portability constraint on the config, not a deliverable.
- No OTel content flags, ever (and no OTel pipe at all in v1).
- No replay-rig commitment in v1 (explicit go/no-go later).
- Not a product. This is a personal instrument; role-level abstractions may be published later, but shareability is not a design constraint on day 1.

## Day-one actions (do these first, independent of everything else)

1. **Raise `cleanupPeriodDays` to effectively-never (`99999`).** (Executed.) Claude Code defaults to 30 days and was **deleting the historic record.** There is no documented disable sentinel (`0` is rejected, minimum 1); a large value is the supported approach. Operator intent: let transcripts accumulate, tune retention only after the lake is sorted.
2. **Pin `duckdb` in the harness mise baseline.** (Executed.) The engine pin lives in this repo's `mise.toml` (Renovate keeps it current) so the engine is reproducible and version-locked. No container, no image manifest to verify.
3. **Install the DuckDB `vss` + `fts` + `sqlite` extensions** on first use (vector similarity, full-text search, SQLite scanner) -- W7 clustering/text mining and the W2 opencode adapter depend on them. All three are official extensions; a one-time `INSTALL` fetches extension code, never content.
4. **Start the W7 correction record -- which is retention + ingest, not hand capture** (mining-first; this action's original curated-capture wording was withdrawn the same day it was written, RFC-0002 History). The signal is longitudinal, but the lake IS the capture surface: with #1 executed and ingest running, every in-session correction is already accumulating, retroactively and completely -- no hand-fed ledger. Two boundary notes: corrections arriving out-of-band (outside any session) are covered by the operator's standing paste-back practice -- they get brought back into a session, so the transcript record carries them; and phase-2 classification must recognize those paste-backs as rewrite events, not noise.

---

## Pivot record (2026-07-06)

**What was preselected.** The campaign scaffold said the stack was "likely clickhouse based," and that preselection rode unchallenged through the first grill and into the first draft of this PRD (ClickStack all-in-one under Apple `container`, OTLP live plane, LaunchAgent/volume/TTL machinery).

**What challenged it.** The operator's entire transcript history -- and it is all of it, since the 30-day cleanup already ate the rest -- is **774 MB across 782 JSONL files, ~56K API calls**. Even heavy multi-year use projects to single-digit GB of raw text and low-millions of structured rows: **3-4 orders of magnitude below ClickHouse's design point**. A live demo installed DuckDB (fresh single binary) and aggregated the full history in place in seconds. Nearly all of the old W1's machinery (container runtime, LaunchAgent workarounds, colima fallback, volume management, TTL surgery, Mongo dependency, disk scripts) existed only because the engine was server-shaped.

**What the operator approved.** Pivot to a file-first Parquet lake + DuckDB (files canonical, engines disposable). Defer OTLP entirely ("I don't know that we need OTLP"). Drop Apple `container` from scope ("prove the concept before we attempt to think of running it at scale"). ClickHouse/ClickStack and Apple `container` are **deferred, not rejected** -- their research is retained in the Appendix as deferred-stage reference for whenever a server-shaped component exists. *(Recorded as ADR-0002.)*

**W1 measurement note (2026-07-06).** The pre-pivot "~56K API calls" counted raw top-level assistant lines (57,258). The full corpus -- including 728 subagent transcript files nested at `<session>/subagents/agent-*.jsonl`, 92% of all files and silently dropped by any non-recursive glob -- is 794 files / 783 MB / 91,806 raw usage lines, deduplicating to **40,957 unique API calls** on the (message id, request id) grain. The scale conclusion is unchanged: still 3-4 orders below ClickHouse's design point.

---

## Workstreams

Continuity mapping from the campaign: **W1**←O1, **W2**=new (now primary), **W3**←O2 (deferred), **W4**←O3, **W5**←O4, **W6**←O5 (expanded), **W7**←O6.

### W1 -- Lake foundation (was O1 "Stack foundation")

Lay down the file lake and the disposable engine, reproducible via `just`. No server, no container, no listener. Code home: this repo (`gitlab.com/dunn.dev/varve` -- `adapters/`, `queries/`, `justfile`). Data home: `~/.local/share/varve/` (never in the repo).

Contents:
- **Parquet partitions** under `~/.local/share/varve/lake/`, partitioned by runtime and date (e.g. `~/.local/share/varve/lake/runtime=claude-code/date=2026-07-05/*.parquet`). zstd-compressed. This is the canonical artifact.
- **`~/.local/share/varve/varve.duckdb`** -- a DuckDB database file holding views and materialized marts over the Parquet (not the source of truth; rebuildable from Parquet + adapters).
- **Adapters (`adapters/`) + SQL query library (`queries/`)**, versioned in this repo.
- **`justfile`** targets: `just backfill` (adapters → Parquet from all history), `just ingest` (incremental), `just sql` (open DuckDB with views attached), `just disk` (report lake size + tripwire at ~100 GB).
- **`duckdb` mise-pinned** (day-one action #2) so the engine is reproducible.

Findings to bake in:
- DuckDB reads the raw Claude Code JSONL in place (`read_json_auto`), so the v1 Claude Code adapter is largely SQL views / `CREATE TABLE AS SELECT` (CTAS) into Parquet -- minimal bespoke code. pi (JSONL) and opencode (SQLite/WAL) still need real adapter code.
- Extensions: `vss` (vector similarity) + `fts` (full-text) cover W7 re-litigation clustering and text mining at this scale.
- **Single-writer constraint:** DuckDB allows one writer. Discipline: the cron/`just ingest` target is the sole writer; interactive analysis attaches **read-only**. See Risks.
- Licenses clean: DuckDB MIT.
- **Portability:** Parquet + the SQL library port to ClickHouse unchanged (ClickHouse reads Parquet natively). The engine swap is a team-stage/x86 concern, not a rewrite.

**Acceptance criteria:**
- `just backfill` produces normalized Parquet from `~/.claude`; row counts and summed cost reconcile against ccusage on the same transcripts (within a stated tolerance).
- `just ingest` is incremental and idempotent (no duplicate rows on re-run).
- `just sql` opens DuckDB with all lake views attached and answers a burn-by-day query.
- `just disk` reports lake size and warns at ~100 GB.
- **Zero resident processes** after any target completes; nothing bound to any interface (verified: no listening socket).

### W2 -- Transcript plane (new; now primary)

Normalized schema as Parquet partitions, exposed as DuckDB views; adapters in priority order **Claude Code → pi → opencode**; incremental ingest (cron or `just ingest`) + full historical backfill; version-tolerant parsers. This is the novelty: [ccusage](https://github.com/ryoppippi/ccusage) (and the ccusage org's Rust rewrite) proves the per-runtime adapter approach works, but it emits CLI reports, not a queryable warehouse with `tool_calls`/corrections. No published stack has the queryable-warehouse shape (Parquet/DuckDB or ClickHouse) -- all prior Claude Code telemetry stacks are Prometheus/Grafana ([ColeMurray/claude-code-otel](https://github.com/ColeMurray/claude-code-otel), [acreeger/claude-code-metrics-stack](https://github.com/acreeger/claude-code-metrics-stack), [NikiforovAll/ccdashboard](https://github.com/NikiforovAll/ccdashboard), [Grafana #25052](https://grafana.com/grafana/dashboards/25052)). Borrow ccusage's adapter knowledge; build the warehouse.

Common tables (Parquet partitions, exposed as DuckDB views): `sessions`, `messages`, `api_calls` (per-call token/cost usage), `tool_calls`; later `correction_events` (W7). All parsers are **version-tolerant** -- pinned per observed schema version; ingest failures **alert, do not crash**.

**Lake table shapes (the shape, not the DDL -- the schema is an open design, RFC-0001):**

| Table | Grain | Key fields (runtime-specific are nullable) |
|-------|-------|--------------------------------------------|
| `sessions` | one row per session | session_id, runtime, cwd, harness, estate, campaign (derived, W4), started_at, parent_session_id (nullable -- empty for pi children) |
| `messages` | one row per message | message_id, session_id, role, parent_id (tree for pi), is_sidechain (Claude Code), timestamp |
| `api_calls` | one row per model call | session_id, message_id, timestamp, model, provider, input, output, cache_read, cache_write, cost_usd (this is the ccusage `UsageEntry` grain) |
| `tool_calls` | one row per tool invocation | session_id, message_id, tool_name, started_at, ended_at, duration_ms (NULL except opencode), decision (nullable) |
| `correction_events` | W7 | see W7 schema |

Cost lives at the `api_calls` grain everywhere, so cost analytics (W5) and counterfactuals (W6 v1) are SQL over one table.

Adapter findings:
- **Claude Code** (`~/.claude/projects/<dashed-cwd>/<session-id>.jsonl`): per-API-call `usage` blocks (tokens incl. cache read/creation, model, timestamps); `is_sidechain` markers exist though subagent transcripts flow through the parent session file. Format internal / subject to change. **v1 shortcut:** DuckDB `read_json_auto` reads these in place, so the v1 Claude Code adapter can be near-pure SQL (views + CTAS to Parquet); it graduates to a real normalizer once incremental idempotent ingest and multi-runtime schema alignment demand it. (Day-one action #1 -- `cleanupPeriodDays` -- lives here.)
- **pi** ([earendil-works/pi](https://github.com/earendil-works/pi), `docs/session-format.md`; formerly badlogic/pi-mono): `~/.pi/agent/sessions/<dir-encoded>/<ts>_<id>.jsonl`, append-only, versioned header (v3, auto-migrated), **tree-structured** messages (`id`/`parentId` -- branching, not linear). `AssistantMessage` carries per-API-call usage AND inline-computed cost (input/output/cacheRead/cacheWrite, total), ~29 providers. Limitation: pi subagents spawn `pi --no-session` children -- **no transcript written for the child**; parent records only a rolled-up usage blob. Accept as an upstream gap; child-session linkage is empty for pi.
- **opencode** ([anomalyco/opencode](https://github.com/anomalyco/opencode), formerly sst/opencode): storage moved to SQLite in v1.2.0 (~Feb 2026): `~/.local/share/opencode/opencode.db`, write-ahead-log (WAL) mode; legacy per-message JSON still read as fallback. **Pin to V1 tables** (`session`/`message`/`part` -- the preserved contract); V2 event tables are maintainer-declared disposable. Usage at three granularities incl. per-step; opencode computes cost itself (defend against the historic `cost:0` discrepancy ccusage reported). Adapter needs a SQLite/WAL reader with lock handling, not a line-tailer -- DuckDB's official `sqlite` extension can `ATTACH` the database directly, so much of this adapter can also stay SQL (WAL/lock care still applies).
- **Normalization:** ccusage `UsageEntry` is the denominator (above). Only opencode has tool-call start/end timestamps -- `duration_ms` is NULL elsewhere. OTel GenAI semantic conventions (`gen_ai.*`, checked at SEMCONV v1.43.0) are all `stability: development` -- **borrow the names as vocabulary; do not depend on the contract.** *(Normalization choice recorded as ADR-0006.)*

**Acceptance criteria:**
- Claude Code adapter ingests a full backfill of `~/.claude` into Parquet with per-API-call rows; row counts and summed cost reconcile against ccusage on the same transcripts (within a stated tolerance).
- Incremental ingest picks up new/appended sessions without duplicating rows (idempotent on session_id + call index).
- A deliberately malformed / newer-schema record is logged and skipped, not fatal.
- pi and opencode adapters land later in sequence; pi child-session gap and opencode `cost:0` defense are documented in the adapter.

**W2 status (2026-07-06).** All three adapters built. **Claude Code** + **opencode**
land on this machine; **pi** is a clean skip (no pi install). Per-runtime row counts
from full backfill: CC 65 / 143,761 / 41,278 / 46,698 (sessions/messages/api_calls/
tool_calls -- api_calls tracks live corpus drift; a frozen-source A/B proved the W2
refactor byte-identical to W1, zero regression); opencode 1,626 / 82,690 / 73,717 /
89,684. Idempotence holds across runtimes (backfill -> ingest -> ingest identical).
opencode is read via a read-only APFS clone -- its live db is byte-identical (sha256)
before/after; zero resident processes, zero egress. opencode surfaces its priced
inline cost (Anthropic/OpenAI/Google) with GitLab-Duo subscription models correctly
\$0/unpriced. Schema decisions, the pi subagent coverage hole, the opencode api_calls
grain, and the attribution-seed gap (opencode cwds under the historical work
namespaces route to `unknown`) are recorded in RFC-0001 (W2 build results). pi is
correct-by-construction against the v3 spec but UNVALIDATED against real files.

### W3 -- Live counts plane (was O2) -- DEFERRED

*Full deferred design in RFC-0004 §a.* **Not built in v1.** Rationale: transcripts are canonical, so a live telemetry pipe adds a resident listener and a confidentiality surface to prove-out for near-real-time counts we do not yet need. The old design already declared telemetry loss acceptable. Do **not** add `CLAUDE_CODE_ENABLE_TELEMETRY` / `OTEL_*_EXPORTER` keys to `settings.json`.

**Later option (documented, not scheduled):** an `otel-collector` single binary with a file exporter writing into the same Parquet lake, or ClickStack at the team stage. Claude Code's counts-only metric set (`token.usage`, `cost.usage`, `session.count`, `active_time.total`, `code_edit_tool.decision`, events `skill_activated` / `tool_decision` / `compaction` / permission decisions) is genuinely rich and would supplement the transcript plane with near-real-time views. **Retained invariant (I1):** if this ever wakes, every `OTEL_LOG_*` content flag stays OFF, verified by network capture; the pipe carries counts/metadata only. `cost.usage` is locally computed and may differ from billing -- console authoritative.

### W4 -- Attribution (was O3)

Slice everything by harness/estate/campaign.

**The only channel in v1 (no dependency):** the transcript adapter derives harness/estate/campaign at ingest time by mapping the transcript's cwd/project directory onto the estate layout. Deterministic, retroactive, works for historical backfill. With the live plane deferred (W3), this is the whole of attribution -- and it is the stronger channel anyway. *(Recorded as ADR-0005.)*

**Documented for later (with the live plane; RFC-0004 §c):** per-launch env injection via `OTEL_RESOURCE_ATTRIBUTES` (`key=value,...`; propagates as metric labels) would need the session manager to set env at launch. Session-manager touchpoints: all launch paths funnel through a single launch-command composer, which builds a shell string delivered via `tmux send-keys`; campaign metadata (category from campaign frontmatter) is loaded there; the existing session-env config sets tmux `-e` vars but lacks category/estate. Recommended shape when it is scheduled (option 1): inline env-prefix in the launch composer -- add an estate field + a templated env map (`{repo} {campaign} {category} {estate}`), prepend `KEY='val'` to the tool command (~30-40 lines, one function). Alternates: option 2 (resolver-exported env), option 3 (wrapper-script self-derivation). Not scheduled in v1; no session-manager issue/MR is a v1 deliverable.

**Acceptance criteria:**
- Every `sessions` row carries derived `harness`, `estate`, `campaign` from cwd mapping, including on backfilled history.
- Cost/burn queries slice by estate and campaign from the transcript plane alone.

### W5 -- Cost + efficiency analytics (was O4)

The **versioned SQL query library is the real artifact**; a presentation layer is optional and later. The library, run against DuckDB over the Parquet lake:
- Burn by estate / campaign / model / day.
- Dispatch ratio (coordinate-by-default adherence -- main vs subagent work, from sidechain/parent-session markers in the transcript plane).
- Recycle-threshold validation (does context stay dense under the 120K/180K discipline?).
- Accept/reject rates (`code_edit_tool.decision`, from the transcript plane).
- Re-litigation proxies (G2, counts-level): repeated permission denials, repeated overrides, recurring interruption patterns -- the cheap tier of W7's content-level analysis.
- Cache efficiency (cache-read vs creation vs input).
- **Cost validation:** transcript-derived cost vs console/ccusage (there is no OTel plane to cross-check against in v1).

**First recorded result (from the pivot demo):** cache-read tokens outnumber fresh input ~2000:1 on the primary model (15.6B vs 6.7M) -- the cost structure is cache-read-dominated, which is exactly the recycle-discipline evidence W5 targets.

**Presentation layer:** optional, decide when queries exist (candidate tools in Open questions). DuckDB output feeds a notebook or a static report just as well as a dashboard; no always-on UI is required.

Consumer: the context-economics campaign. This campaign **produces evidence**; that one **sets hypotheses**.

**Acceptance criteria:**
- Query library is versioned in the repo (`queries/`), each query documented (inputs, what it answers).
- Burn-by-estate/campaign/model/day query returns from backfilled data via `just sql`.
- The transcript-derived-vs-console cost check runs and reports the divergence.

### W6 -- Historic record → simulation + benchmarks (expanded O5)

One workstream, three staged shapes. Serves G4.

- **v1 -- cost counterfactuals + design priors.** SQL arithmetic over `api_calls`: re-price historic dispatches under a different model, re-shape inline-vs-dispatch ("re-price these 40 dispatches at sonnet prices"). Design priors: session shapes, tool mixes, where sessions go long, dispatch ratios, recycle-threshold validation as decision evidence.
- **v2 -- workload abstraction for benchmark synthesis (design RFC-0003).** Derive task-shape distributions from history, scrub all content, generate synthetic benchmark analogs that do **not** leak client or estate content. Feeds the context-economics campaign's existing benchmark-design note as its shared spine.
- **v3 -- replay rig (go/no-go later, not committed in v1).** Re-run recorded workloads under changed config, diff cost/outcome. Real spend and workload-fixity problems -- explicit decision point after v1/v2.

**Acceptance criteria:**
- v1: a counterfactual query re-prices a named set of historic dispatches under an alternate model and reports the delta; at least one design-prior query answers a live harness-design question.
- v2: a synthetic benchmark task is generated from history and audited to contain no sector, account, research, or estate identifiers.
- v3: a written go/no-go with the workload-fixity and spend analysis (no build until approved).

### W7 -- Correction mining (was O6)

*Method design in RFC-0002.* Instrument the DELTA between model-default output and operator-corrected output as a longitudinal, n-of-1 signal. Begin the record **early** -- the longitudinal clock starts the day retention + ingest start (day-one #1; mining is retroactive over everything the lake holds). Private-first; team abstraction later (D6).

**Channel architecture (mining-first -- RFC-0002; its History records the withdrawn curated-ledger design):**
- **mined (primary)** -- detection passes over the lake emit `correction_candidates` (tool-decision rejections, interrupt-then-redirect, lexical correction openers, rewrite detection; the OTel counters `code_edit_tool.decision`/`tool_decision` supplement this only if the live plane ever wakes);
- **adjudicated** -- operator review of mined candidates at analysis time supplies the precision verdict and `context_judgment`; confirmed candidates promote into `correction_events`;
- **opt_in** -- deliberate draft-vs-rewrite diffs when the operator chooses to make one. The operator's standing voicing rules stay distilled-rules-only: analysis output feeds them, never the reverse.

**Re-litigation detection (G2).** The stretch goal generalizes correction mining from style divergence to decision recurrence: cluster semantically-similar operator interventions (corrections, repeated instructions, overrides) across sessions; rank clusters by recurrence × cost. A high-recurrence cluster is a harness-tuning backlog item, ranked; its durability field then measures whether the fix held. Schema impact: nullable `recurrence_cluster_id` on correction events.

**Clustering dependency (staged).** Semantic clustering needs embeddings or labels; DuckDB's `vss` extension searches vectors but does not produce them. At n-of-1 volume (hundreds of events), LLM-assisted labeling inside a harness session suffices and needs zero new infrastructure -- it is the same exposure class as the sessions that produced the content, riding the same API path. Graduate to local embedding generation (e.g. sentence-transformers via `uv`, model weights cached locally) + `vss` indexes when volume demands. Embedding vectors of work content never leave the machine; third-party embedding APIs are excluded.

**Abstraction ladder (D6, extends the team side quest).** Stage 1 -- n-of-1 (this scope): the operator's own divergence + re-litigation signal. Stage 2 -- team conventions: the role-level method write-up + reference config, after stage 1 proves signal. Stage 3 -- post-training decision instrument (G3): a saturation criterion over stage-1-style measurements -- divergence categories whose distilled rules repeatedly fail the durability test (`recurred_after_bake` true across interventions) are the quantitative case that context engineering has saturated and post-training on team corrections would pay off, reported at group/project scope. Stages 2-3 are not built here; stage 1's schema (durability + recurrence) is designed so their measurements fall out of it. Note: the saturation criterion is hypothesized-novel -- the prior-art sweep did not cover this exact claim; verify before any external positioning.

**What is genuinely novel** (per the prior-art sweep -- position honestly; the team extension is the *least* novel part):
1. The measured object is the **delta itself** -- a controlled taxonomy of divergence directions (verbosity, hedging, structure, tone, formatting).
2. A per-event **context-adjudication field** separating "genuine preference" from "model lacked context" -- no prior system operationalizes this confound.
3. Three-channel fusion.
4. A **durability test** -- after baking a correction into the harness, does the divergence stop recurring ("land once and hold" as a measured closed loop)?
5. n-of-1 longitudinal framing with model version as a controlled covariate.

**Prior art** (nearest neighbors, none does the above): PRELUDE/CIPHER (Gao et al., NeurIPS 2024 -- learns latent preferences from user edits, but optimizes outputs rather than characterizing the gap; [arXiv:2404.15269](https://arxiv.org/abs/2404.15269)); DRIFT (2025); machine-translation post-editing literature; Copilot acceptance-rate studies (Ziegler et al., CACM 2024); industry annotation-queue tools (Langfuse etc.) treat corrections as eval labels, not a preference-divergence stream; Cursor rules / CLAUDE.md distillation is manual and unmeasured ("Beyond the Prompt", 2025).

**Method risks + mitigations** (baked into the schema):
- Selection bias (only some outputs corrected) → log a denominator: sampled uncorrected outputs, `sampled_vs_organic` flag.
- Confounding → mandatory `context_available_judgment` field {had_context | lacked_context | ambiguous}; stratify analyses.
- Non-stationarity → record exact model version strings; treat version as covariate; re-baseline on model bumps.
- Small n → use divergence **category** as the unit of analysis, not the event; human-in-the-loop on distillation.

**Correction-event schema (full version in RFC-0002; adapt into the W2 DDL):** `event_id`, `timestamp`, `channel` {mined | opt_in} with adjudication provenance (`adjudicated_at`, `verdict`), `artifact_type` {code_edit | prose | commit_msg | plan | config}, `model_identity` {model_id, version, params}, `context_ref`, `model_draft_ptr` + `operator_rewrite_ptr` (**local-only refs**), `decision` {accepted | rejected | partial | edited}, `divergence_category` (multi-label controlled taxonomy), `divergence_direction` (signed), `magnitude`, `context_available_judgment`, `selection_metadata`, `distilled_rule_id` (nullable), `recurrence_cluster_id` (nullable), `durability` {intervention_ref, recurred_after_bake, observation_window}, `privacy` {local_only, redaction_status}.

**Confidentiality:** content NEVER rides the OTel pipe. Published output (if any) is a role-level abstraction -- no sector, no estate, no account or research identifiers.

**Acceptance criteria:**
- Phase-1 mining emits `correction_candidates` from the lake, and an adjudication round promotes confirmed candidates into `correction_events` (gates: >=0.8 per-detector precision, a recall-floor sample, idempotent re-mining -- RFC-0002).
- A `correction_events` table exists with the schema above; `context_available_judgment` and `selection_metadata` are non-null on every event.
- At least one divergence category has enough events to test durability (recurred_after_bake) across one model-version boundary.
- A re-litigation report ranks recurring operator interventions by recurrence × cost; at least one cluster graduates to a harness change with a durability observation window.

---

## Sequencing

```
W1  ─▶  W2(CC)  ─▶  W5 v1 queries + W4  ─▶  W6 v1
                          │
   W7 record START ───────┘  (= retention + ingest; the lake is the capture -- RFC-0002)
                          │
                      W6 v1  ─▶  W2(pi, opencode)  ─▶  W6 v2  ─▶  stage decisions (W6 v3 / W7 depth / team stage)
```

W1 first (foundation). Then the W2 Claude-Code adapter. W5 v1 queries make it useful; W4 attribution rides the same ingest. **The W7 record starts as early as W1 lands (retention + ingest; mining itself is W7 phase 1 and is retroactive) -- it does not wait for W5/W6.** W6 v1 queries, then the pi and opencode adapters (opencode validates the abstraction and the operator asked for it in design), then W6 v2, then the stage decisions (W6 v3, W7 analysis depth, and whether a server-shaped team stage is warranted). W3 (live plane) is out of the v1 flow.

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| DuckDB single-writer | Concurrent writes corrupt / block | Discipline: cron/`just ingest` is sole writer; interactive analysis attaches read-only |
| Engine re-entry at team stage | Rework to move off DuckDB | Mitigated by design: Parquet + the SQL library port to ClickHouse natively; the engine is the disposable part |
| Transcript format drift (all three runtimes internal/unstable) | Ingest breaks silently | Version-tolerant parsers, pinned per observed schema version; ingest failures **alert, not crash** |
| opencode SQLite/WAL locking | Adapter reads corrupt/blocked | Proper WAL reader with lock handling; not a line-tailer |
| pi subagent invisibility (`--no-session` children) | Child-session cost/linkage missing | Accept upstream gap; record parent rolled-up usage; document empty linkage |
| Locally-computed cost vs billing divergence | Wrong cost figures | Console authoritative; transcript-derived cost cross-checks vs console/ccusage; state tolerance |
| Disk growth (keep-everything) | Disk fills | Nearly moot at this scale (zstd Parquet); `just disk` tripwire at ~100 GB is the cheap control |
| Confidentiality -- content in a queryable local lake | Exposure surface | Same-disk argument (content already in `~/.claude`); **no listener at all in v1** -- no bound port, not even localhost |
| Correction-mining method risks | Biased/confounded signal | Folded into W7 (denominator, context judgment, version covariate, category-as-unit) |

## Open questions (not settled)

- **Presentation layer choice.** marimo, Evidence, a static report tool, or none -- decide when the W5 queries exist. Not required for v1.
- **W6 v3 go/no-go** (RFC-0003 notes the gate). Replay rig: build or not, after v1/v2.
- **Adjudication cadence** (RFC-0002). Mining is retroactive, so raw capture loses nothing -- but `context_judgment` is supplied by operator memory at review time and decays with distance from the event. Once phase-2 classification runs, set a cadence for adjudication rounds so the confound label stays reliable. (This is what survives of the withdrawn "every week not capturing is data lost" urgency; the capture-minimum question it replaces was resolved by the mining-first reversal.)
- **G3 saturation criterion** (RFC-0004 §d). The exact statistical form of "durability-resistant divergence mass" that justifies post-training -- a stage-3 design task, after stage-1 data exists.
- **Team-stage engine trigger** (RFC-0004 §b). What concretely warrants standing up ClickStack/ClickHouse (always-on, multi-writer, multi-user, or the x86 box) -- revisit after v1 proves the concept.

## Relationship to the context-economics campaign

The context-economics campaign = the **levers** (recycle, model tier, coordinate, terseness, sharding) + the tiering benchmark. varve (the observability campaign's instrument) = the **instrument** that measures whether those levers work + a substrate for new experiments. Economics sets the hypothesis; varve supplies the evidence (W5 is the handoff surface). The context-economics campaign's benchmark-design note is the **shared spine** for W6 v2. **This campaign supersedes the context-economics campaign's W6 workstream** -- surface that to the (actively-driven) context-economics session and update its pointer by coordination, not unilateral edit.

## Appendix -- key sources by topic

**Engine (v1).** DuckDB: https://duckdb.org/ (MIT). `read_json_auto` for in-place JSONL; `vss` extension (vector similarity) https://duckdb.org/docs/extensions/vss , `fts` extension (full-text) https://duckdb.org/docs/extensions/full_text_search . Apache Parquet: https://parquet.apache.org/ . mise-pinned `duckdb` (current pin in `mise.toml`).

**Stack / ClickStack -- DEFERRED-STAGE reference (team/always-on, not v1).** ClickStack (HyperDX) docs: https://clickhouse.com/docs/use-cases/observability/clickstack . Image `clickhouse/clickstack-all-in-one` (legacy `docker.hyperdx.io/hyperdx/hyperdx-all-in-one`). Ports 8080 / 4317 / 4318; ClickHouse 8123 / 9000. Licenses: ClickHouse Apache-2.0, HyperDX MIT, bundled OTel Collector Apache-2.0. ClickHouse reads Parquet natively (the lake ports directly). Alternatives evaluated: SigNoz, Grafana+ClickHouse DIY, OpenObserve, Uptrace.

**Apple `container` runtime -- DEFERRED-STAGE reference (whenever a server-shaped component exists).** Repo: https://github.com/apple/container (v1.0.0, 2026-06-09). Open issues to weigh at that stage: virtiofs chown-on-bind-mount [#333](https://github.com/apple/container/issues/333), restart policy [#286](https://github.com/apple/container/issues/286), boot auto-start [#158](https://github.com/apple/container/issues/158), apiserver plist not auto-discovered [#1321](https://github.com/apple/container/issues/1321). Fallback then: colima (free/MIT). Excluded: Docker Desktop, OrbStack (licensing).

**Transcript adapters.** ccusage: https://github.com/ryoppippi/ccusage (+ ccusage-org Rust rewrite) -- adapter proof, `UsageEntry` denominator. pi: https://github.com/earendil-works/pi (`docs/session-format.md`). opencode: https://github.com/anomalyco/opencode (SQLite v1.2.0). Prior-art telemetry stacks (all Prometheus/Grafana, none ClickHouse): https://github.com/ColeMurray/claude-code-otel , https://github.com/acreeger/claude-code-metrics-stack , https://github.com/NikiforovAll/ccdashboard , https://grafana.com/grafana/dashboards/25052 .

**OTel semantic conventions.** GenAI `gen_ai.*` at SEMCONV v1.43.0 -- all `stability: development`: https://github.com/open-telemetry/semantic-conventions . Names as vocabulary only.

**Correction-mining prior art.** PRELUDE/CIPHER (Gao et al., NeurIPS 2024): https://arxiv.org/abs/2404.15269 . DRIFT (2025). Copilot acceptance (Ziegler et al., CACM 2024). Langfuse annotation queues. "Beyond the Prompt" (2025). None measures the divergence delta with a context-adjudication confound control.

**Session manager.** The session manager (Rust) composes every launch command as a shell string delivered via tmux, loading campaign metadata at spawn; its session-env config sets per-launch env vars. Option-1 env-prefix injection recommended (upstream feature).
