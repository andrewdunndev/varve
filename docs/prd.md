# varve: Product Requirements Document (PRD)

*varve (n.): one annual sediment layer in a glacial lake; read in sequence, varves reconstruct history. This instrument accumulates readable layers of coding-agent session records and mines them for signal.*

**Status:** decided (architecture settled; the lake DDL settled in RFC-0001; presentation layer and stage gates remain open).
**Scope:** local, single user, one machine.
**Repo:** `gitlab.com/dunn.dev/varve`, a public instrument. Your rules, names and readings live outside the repo (the data home) and never appear in committed artifacts.
**Decision records:** settled choices are architecture decision records (ADRs, `docs/adr/`); open designs are requests for comment (RFCs, `docs/rfc/`).

## Summary (read in 10 seconds)

Build a local session-record lake, not a dashboard, and make the lake files, not a server. Per-runtime adapters normalize on-disk session records into [Apache Parquet](https://parquet.apache.org/) partitions under `~/.local/share/varve/`; [DuckDB](https://duckdb.org/), a single mise-pinned binary, queries them in place. Zero resident processes, no listeners, nothing bound, not even localhost. The canonical artifact is the Parquet plus the schema plus the versioned SQL query library; the engine is disposable. A single user's whole transcript history sits three to four orders of magnitude below ClickHouse's design point, and DuckDB aggregates it in seconds. ClickHouse/ClickStack is deferred to the stage that needs always-on, multi-writer or multi-user access; it reads Parquet natively, so the lake ports directly. The live OpenTelemetry (OTel) counts plane is deferred too: transcripts are canonical and the concept must be proven first.

## Decisions made (read in 30 seconds)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Center of gravity | **Session-record lake first, observability second** | Mine transcripts, do not just watch metrics. Runtime-agnostic; enables history from day one; a runtime with no telemetry still gets full coverage. *(ADR-0001)* |
| D2 | Engine | **Parquet lake + DuckDB (v1); files canonical, engines disposable.** ClickStack deferred to a team/always-on stage | A single user's history is 3-4 orders of magnitude below ClickHouse's design point; DuckDB aggregates it in seconds. Parquet ports to ClickHouse natively when a server is needed. *(ADR-0002)* |
| D3 | Runtime | **No container runtime in v1; mise-pinned binaries.** Apple `container` deferred until a server-shaped component exists | Prove the concept before adding runtime overhead. A single-binary DuckDB has no container, LaunchAgent, volume or vmnet surface to manage. *(ADR-0002)* |
| D4 | Retention | **Keep everything.** No TTL cull, no hard cap. Disk tripwire at ~100 GB | The historic record is the asset. zstd-compressed Parquet makes keep-everything cheap at this scale. *(ADR-0003)* |
| D5 | Attribution | **Build-time cwd→estate/campaign mapping is primary**; launch-time env injection secondary | The transcript mapping is deterministic, retroactive and works on history, so no launcher feature is a blocker. *(ADR-0005)* |
| D6 | Team side quest | **Private-first, abstract later** | Prove the signal on one user; the team deliverable is a role-level method write-up plus reference config, extracted after it works. Abstraction ladder: n-of-1 → team conventions → post-training decision instrument (G3). |
| D7 | Content posture | **Content enters the lake only through the build from the mirror, local-only.** No listener at all in v1 | Nothing is bound, so there is no intake surface to secure. Content is exactly what already sits in `~/.claude`; the lake makes it queryable without changing its exposure. *(ADR-0004)* |
| D8 | Deployment | **Local for this scope**; the lake must later port to a server | Portability is a constraint on config, not a deliverable here. Parquet + SQL port unchanged; the engine swaps to ClickHouse at that stage. *(ADR-0002)* |
| D9 | Live counts plane | **Deferred.** No OTLP wiring in v1 | Not needed to prove the concept; transcripts are canonical and telemetry loss is acceptable. |

## Goals (a ladder)

1. **Table stakes (G1): efficiency wins from history.** Find opportunities, in behavior, agent configuration and skills, to cut spend and token burn. Concrete: re-price historic dispatches under other models; measure dispatch ratios, cache efficiency, where sessions go long.
2. **Stretch (G2): tuning adequacy.** Are you tuning your agent setup enough? Do you re-litigate the same decisions? The signal is recurrence: the same correction or instruction issued across sessions means context belongs in the setup, and the durability test measures whether baking it in made the recurrence stop. Count-level proxies live in the query library; the content-level analysis is correction mining (RFC-0002).
3. **Far stretch (G3): team-level post-training decision instrument.** Detect, at team level, codified preference drift from baseline model training with enough confidence to justify going beyond context engineering into post-training for a specific effort. The measurable criterion: divergence mass that is large, consistent and durability-resistant (categories where distilled rules repeatedly fail to hold are the post-training candidates). This scope builds the n-of-1 instrument that produces those measurements; the service itself is out of scope.
4. **Supporting (G4): historic record → simulation.** Use the record as decision evidence for agent-setup design, in three staged shapes: cost counterfactuals, design priors, and (later, go/no-go) a replay rig; plus workload abstraction for a benchmark system that never leaks real work.

## Architecture (read in 60 seconds)

```
  Runtimes (on-disk records)        Build (just sync, just build)  Lake (files) + engine (disposable)
  --------------------------        --------------------          ----------------------------------
  Claude Code  ~/.claude/*.jsonl ─┐                               Parquet partitions
  pi           ~/.pi/*.jsonl     ─┼─ transcript adapters ──────▶  ~/.local/share/varve/lake/runtime=*/date=*/*.parquet
  opencode     opencode.db       ─┘  (cwd→estate mapping,                     │
                                      version-tolerant)                       ▼
                                                                 DuckDB views generated at startup by bin/duck
                                                                             │
                                                                             ▼
                                                                 SQL query library / notebooks / reports

  No server. No container runtime. No listener of any kind. Zero resident processes. Zero egress.
```

**Transcript plane (primary, canonical, runtime-agnostic; the only plane in v1).** Per-runtime adapters read each runtime's on-disk session records and normalize them into shared-schema Parquet partitions; DuckDB reads one generated view per lake folder. Full content, local-only. Serves G2, G3 and G4; reads existing transcripts from the mirror. The common denominator is [ccusage](https://github.com/ryoppippi/ccusage)'s `UsageEntry` (session_id, timestamp, model, provider, usage{input, output, cache_read, cache_write}, cost_usd), validated across all three runtimes at per-API-call granularity (ADR-0006). Runtime-specific fields are nullable. Parsers are version-tolerant, pinned per observed schema version; a runtime whose adapter fails keeps its last good partitions and the build reports it.

**Lake tables** (Parquet partitions, exposed as DuckDB views; DDL in RFC-0001):

| Table | Grain | Key fields (runtime-specific are nullable) |
|-------|-------|--------------------------------------------|
| `sessions` | one row per session | session_id, runtime, cwd, harness, estate, campaign (derived at build), started_at, parent_session_id (nullable; empty for pi children) |
| `messages` | one row per message | message_id, session_id, role, parent_id (tree for pi), is_sidechain (Claude Code), timestamp |
| `api_calls` | one row per model call | session_id, message_id, timestamp, model, provider, input, output, cache_read, cache_write, cost_usd (the ccusage `UsageEntry` grain) |
| `tool_calls` | one row per tool invocation | session_id, message_id, tool_name, started_at, ended_at, duration_ms (NULL except opencode), outcome (nullable) |
| `correction_events` | one row per confirmed correction | RFC-0002 |

**Attribution columns.** Every `sessions` row carries three tags derived from its working directory at build (ADR-0005), through a mapping file you keep outside the repo (`adapters/attribution.example.toml` is the template): `estate`, a label you assign to a group of directories (for example one forge namespace); `harness`, the repository directory the session ran in; `campaign`, the worktree inside it, if any. Unmatched directories land in an explicit `unknown` bucket.

Cost lives at the `api_calls` grain everywhere, priced at build from `pricing.toml` in the data home (`adapters/pricing.example.toml` is the template), so cost analytics and counterfactuals are SQL over one table.

**Live counts plane: deferred (D9).** Would carry OTel metrics and events over OpenTelemetry Protocol (OTLP), counts only. Not wired in v1: transcripts are canonical and telemetry loss is acceptable. Do not add `CLAUDE_CODE_ENABLE_TELEMETRY` / `OTEL_*_EXPORTER` keys to `settings.json`. The counts-only invariant (I1) is retained for whenever it wakes.

### Confidentiality invariants (load-bearing)

These do not change across any part of the work. If a design choice conflicts with one, the invariant wins. *(Recorded as ADR-0004.)*

- **I1.** (Dormant in v1, retained.) If a telemetry plane is ever wired, every `OTEL_LOG_*` content flag stays OFF and the pipe carries counts + metadata only.
- **I2.** Content enters the system only via the transcript plane, only into the local Parquet lake, only from files already on this disk.
- **I3.** No listeners in v1. Zero egress. No cloud/SaaS backend. Any future listener (team stage) binds `127.0.0.1`.
- **I4.** Your private estates and projects are never named in any committed or published artifact; their identifiers live outside the repo, in the data home. Synthetic benchmarks and any published correction-mining result are role-level abstractions with no sector, account, research or estate identifiers.
- **I5.** Correction-event content (model drafts, user rewrites) is stored as local-only pointers (`model_draft_ptr`, `operator_rewrite_ptr`); it never rides the OTel pipe and is never published verbatim.

## Non-goals

- No cloud/SaaS backend. No egress. Nothing leaves this machine.
- No server, no container runtime, no listener in v1. No always-on process.
- No team deployment in this scope. A later server is a portability constraint on the config, not a deliverable.
- No OTel content flags, ever (and no OTel pipe at all in v1).
- No replay-rig commitment in v1 (explicit go/no-go later).
- Not a product. This is a personal project. Adapter contributions for other runtimes are welcome; there is no support commitment.

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| DuckDB single-writer | Concurrent writes corrupt / block | Discipline: `bin/duck` holds one lock, so a build or a mine is the sole writer |
| Engine re-entry at team stage | Rework to move off DuckDB | Mitigated by design: Parquet + the SQL library port to ClickHouse natively; the engine is the disposable part |
| Transcript format drift (all three runtimes internal/unstable) | The build breaks silently | Version-tolerant parsers, pinned per observed schema version; a failed runtime keeps its last good partitions |
| opencode SQLite/WAL locking | Adapter reads corrupt/blocked | Proper WAL reader with lock handling; not a line-tailer |
| pi subagent invisibility (`--no-session` children) | Child-session cost/linkage missing | Accept upstream gap; record parent rolled-up usage; document empty linkage |
| Locally-computed cost vs billing divergence | Wrong cost figures | Console authoritative; transcript-derived cost cross-checks vs console/ccusage; state tolerance |
| Disk growth (keep-everything) | Disk fills | Nearly moot at this scale (zstd Parquet); `just disk` tripwire at ~100 GB is the cheap control |
| Confidentiality: content in a queryable local lake | Exposure surface | Same-disk argument (content already in `~/.claude`); no listener at all in v1, no bound port, not even localhost |
| Correction-mining method risks | Biased/confounded signal | Denominator sampling, context judgment, model-version covariate, category as unit of analysis (RFC-0002) |
