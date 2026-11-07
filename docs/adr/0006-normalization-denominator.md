# ADR-0006: ccusage UsageEntry as the normalization denominator

- **Status:** accepted
- **Amended by:** ADR-0009 (the record contract adds columns and retires content)
- **Date:** 2026-07-06
- **Deciders:** maintainer

## Context

Three runtimes (Claude Code, pi, opencode) write different session formats, and the
lake needs one shared schema. The question is the greatest common denominator that
holds across all three at useful granularity.

[ccusage](https://github.com/ryoppippi/ccusage) (and the ccusage-org Rust rewrite)
is the de facto transcript-parsing cost CLI, with adapters for Claude Code, Codex,
OpenCode, pi and Goose. It is the empirical proof that the per-runtime adapter
approach works. Its `UsageEntry` (`session_id`, `timestamp`, `model`, `provider`,
`usage{input, output, cache_read, cache_write}`, `cost_usd`) is validated across
exactly these runtimes at per-API-call granularity.

The OpenTelemetry (OTel) GenAI semantic conventions (`gen_ai.*`) name the same
concepts, but at SEMCONV v1.43.0 they are all `stability: development`: a contract
still in motion.

## Decision

- Adopt ccusage's `UsageEntry` as the normalization denominator for the `api_calls`
  grain: per-API-call rows carrying session / timestamp / model / provider / usage /
  cost across all three runtimes. Runtime-specific fields are nullable.
- Borrow OTel `gen_ai.*` names as naming vocabulary only. Do not depend on the
  semantic-convention contract while it is development-stability.
- Adapter priority: Claude Code → pi → opencode. Largest expected volume first;
  opencode third, where it validates the abstraction.
- Accept the known per-runtime gaps rather than block on them:
  - **pi:** `--no-session` subagent children write no transcript; the parent records
    only a rolled-up usage blob. Child-session linkage is empty for pi.
  - **opencode:** SQLite / write-ahead-log (WAL) store since v1.2.0. Pin to the V1
    tables (`session` / `message` / `part`, the preserved contract); treat the V2
    event tables as disposable. Defend against the historic `cost:0` discrepancy.
    DuckDB's official `sqlite` extension can `ATTACH` the database directly (WAL and
    lock care still apply).
  - **`duration_ms` is opencode-only** (only opencode records tool-call start/end);
    NULL elsewhere.

## Consequences

**Positive**
- One schema, empirically validated across all target runtimes. Borrows a proven
  body of adapter knowledge instead of inventing one.
- Per-API-call grain everywhere means cost analytics and counterfactuals are SQL
  over a single table (`api_calls`).

**Negative**
- Ties the core schema to an external project's data model. Mitigated: it is a
  denominator, not a dependency. We reimplement the shape; we do not import the tool.
- Accepts documented blind spots (pi children, opencode `cost:0`).

**Neutral**
- Runtime-specific richness (pi's tree-structured messages, opencode's per-step
  timing) is captured in nullable fields, not forced into the denominator.

## References

- PRD sections: Architecture (transcript plane, lake table shapes); Risks (pi
  subagent invisibility, opencode WAL / cost divergence).
- Related: ADR-0001 (transcript plane), RFC-0001 (lake schema and DDL).
- External: ccusage <https://github.com/ryoppippi/ccusage>; pi
  <https://github.com/earendil-works/pi> (`docs/session-format.md`); opencode
  <https://github.com/anomalyco/opencode>; OTel semantic conventions
  <https://github.com/open-telemetry/semantic-conventions> (SEMCONV v1.43.0).
