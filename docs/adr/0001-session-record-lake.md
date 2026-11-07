# ADR-0001: A lake of session records, not a telemetry dashboard

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** maintainer

## Context

The project started as a metrics stack watching cost and token burn. Counts cannot
serve three of the four goals in the PRD:

- Correction mining needs the content of a model draft and the user's rewrite, to
  measure the difference between them.
- Counterfactuals need per-API-call detail across all history, to re-price past
  work and derive design priors. Aggregates discard that detail.
- Design priors need session shapes, tool mixes and dispatch structure: per-event
  records, not rollups.

Two more facts point the same way:

- The record already exists on disk: `~/.claude`, `~/.pi`, `opencode.db`. A metrics
  pipeline would capture only the future. A transcript approach backfills the past.
- Runtime coverage is a hard requirement (Claude Code, pi, opencode). A
  telemetry-only design excludes any runtime without native OpenTelemetry (OTel). A
  transcript design covers every runtime that writes session files.

## Decision

The transcript plane (the runtimes' own session files on disk) is canonical and the
only data plane in v1. Per-runtime adapters normalize those files into a shared
schema (ADR-0006). Live observability (OTel counts) is secondary and deferred. The
engine choice is ADR-0002.

Lake first, observability second.

## Consequences

**Positive**
- Full history is queryable from day one via backfill. The record that predates the
  instrument is captured.
- Content-level research (correction mining, benchmark synthesis) becomes possible.
- Any runtime that writes session files is in scope.

**Negative**
- No near-real-time counts. A session in flight is invisible until its transcript is
  ingested. Acceptable, because the transcript is the source of truth.
- The design depends on undocumented, drifting on-disk formats. Mitigation:
  version-tolerant parsers pinned per observed schema version (ADR-0006, RFC-0001).

**Neutral**
- Live counts can be added later as a supplement, not a foundation.
- The source erodes if Claude Code's `cleanupPeriodDays` is left at its 30-day
  default (ADR-0003).

## References

- PRD sections: Decisions (D1, D9); Architecture.
- Related: ADR-0002 (files-first engine), ADR-0003 (retention), ADR-0006
  (normalization), RFC-0001 (lake schema).
