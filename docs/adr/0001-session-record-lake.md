# ADR-0001 -- A lake of session records, not a telemetry dashboard

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** operator + session

## Context

The campaign began as an observability play -- a metrics stack watching cost and
token burn. The operator reframed it mid-design: "maybe observability is the wrong
approach -- maybe an approach to mining the session transcripts?"

The reframe is forced by the goals. Three of the four goal-ladder rungs cannot be
served by counts:

- **Correction mining (G2 / W7)** needs the *content* of a model draft and the
  operator's rewrite to measure the delta between them. A counter cannot.
- **Simulation and counterfactuals (G4 / W6)** need per-API-call detail across all
  history to re-price dispatches and derive design priors. Aggregated metrics
  discard exactly the detail this needs.
- **Design priors** need session shapes, tool mixes, and dispatch structure -- again,
  per-event records, not rollups.

Two more facts point the same way:

- The record already exists on disk: `~/.claude`, `~/.pi`, `opencode.db`. A metrics
  pipeline would ignore all of it and capture only the future. A transcript approach
  backfills the past.
- **Runtime-agnostic** is a hard requirement (Claude Code, pi, opencode). A
  telemetry-only design excludes any runtime without native OpenTelemetry (OTel); a
  transcript design covers every runtime that writes session files.

## Decision

The **transcript plane is canonical and the only data plane in v1.** Per-runtime
adapters normalize each runtime's on-disk session records into a shared schema
(ADR-0006). Live observability (OTel counts) is secondary and deferred (the engine
choice is ADR-0002; the live plane itself is parked in RFC-0004 §a).

The slogan is "lake first, observability second."

## Consequences

**Positive**
- Full history is queryable from day one via backfill; the record that predates the
  instrument is captured, not lost.
- Content-level research (correction mining, benchmark synthesis) becomes possible.
  Counts could never support it.
- Runtime coverage is universal: any runtime that writes session files is in scope.

**Negative**
- Telemetry loss is accepted. There are no near-real-time counts, and a session in
  flight is invisible until its transcript is ingested. This is tolerable because the
  transcript is the source of truth.
- The design depends on undocumented, drifting on-disk formats. Mitigated by
  version-tolerant parsers pinned per observed schema version (ADR-0006, RFC-0001).

**Neutral**
- Live counts remain available later as a supplement, not a foundation (RFC-0004 §a).
- The canonical source erodes if Claude Code's `cleanupPeriodDays` is left at its
  30-day default -- addressed by ADR-0003.

## References

- PRD sections: Architecture; W2 -- Transcript plane; W3 -- Live counts plane (deferred).
- Related: ADR-0002 (files-first engine), ADR-0003 (retention), ADR-0006
  (normalization), RFC-0001 (lake schema), RFC-0004 §a (deferred live plane).
