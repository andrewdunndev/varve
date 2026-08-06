# RFC-0004 -- Deferred stage (the parked bundle)

- **Status:** draft
- **Date:** 2026-07-06

## Summary

One RFC to hold everything deliberately deferred, so nothing is stranded: (a) the live
OpenTelemetry (OTel) counts plane, (b) team-scale engine re-entry, (c) session-manager
per-launch env injection, and (d) the G3 post-training decision instrument. Each has a
trigger condition and a rough design. None is built in v1.

## Motivation

The pivot (ADR-0002) and the lake-first decision (ADR-0001) deferred a lot of real
design work. Parking it in one named, structured place keeps it recoverable and
prevents re-litigating it from scratch when a trigger fires. This is the anti-amnesia
document.

## Design

### §a -- Live OTel counts plane

- **Trigger:** a genuine need for near-real-time counts, or the team stage (§b).
- **Shape:** an `otel-collector` single binary with a file exporter writing into the
  same Parquet lake, or ClickStack at the team stage.
- **Invariant:** counts-only; every `OTEL_LOG_*` content flag OFF (ADR-0004, I1),
  verified by network capture.
- **Claude Code inventory** (for when it wakes): metrics `session.count`,
  `token.usage`, `cost.usage`, `lines_of_code.count`, `commit.count`,
  `pull_request.count`, `active_time.total`, `code_edit_tool.decision`; events
  `skill_activated`, `tool_decision`, `api_request` / `api_error`, `compaction`,
  permission decisions. `cost.usage` is locally computed and may differ from billing --
  console authoritative.

### §b -- Team-scale engine re-entry

- **Trigger:** always-on ingest, multi-writer, multi-user, or the x86 Linux box. The
  most likely concrete trigger is DuckDB's single-writer limit (ADR-0002) becoming a
  real constraint.
- **Shape:** ClickStack / ClickHouse. ClickHouse reads Parquet natively, so the lake
  ports with no rewrite -- the engine swaps, the SQL library and schema carry over.
  Deferred-stage references (ClickStack docs, Apple `container` issues) are retained in
  the PRD appendix.

### §c -- Session-manager per-launch env injection

- **Trigger:** the live plane (§a) landing -- the only consumer of launch-time
  attribution. Ingest-time cwd mapping is primary and sufficient for the transcript
  plane (ADR-0005), so this is not otherwise needed.
- **Shape (option 1, recommended):** inline env-prefix at the session manager's
  launch-composition step -- add an estate field to the repo record + a templated env
  map (`{repo} {campaign} {category} {estate}`), prepend `KEY='val'` to the tool
  command (a small change to one function; all launch paths inherit it). Campaign
  metadata already loads at that point.
- **Alternates:** option 2 (resolver-exported env, more surface); option 3
  (wrapper-script self-derivation, config-only stopgap, drift-prone).
- This is an upstream session-manager feature (the operator's own project); not a v1
  deliverable.

### §d -- G3 post-training decision instrument

- **Trigger:** stage-1 (n-of-1) correction data exists and the abstraction ladder
  reaches stage 3 (D6).
- **Shape:** a saturation criterion over stage-1-style measurements -- divergence
  categories whose distilled rules repeatedly fail the durability test
  (`recurred_after_bake` true across interventions) are the quantitative case that
  context engineering has saturated and post-training on team corrections would pay
  off. Reported at group or project scope; the service itself is out of scope.
- **Honest caveat:** the saturation criterion is hypothesized-novel; the prior-art
  sweep did not cover this exact claim (RFC-0002 novelty section). Verify before any
  external positioning.

## Unresolved questions

- Every trigger condition above -- what concretely fires each one.
- §d: the exact statistical form of "durability-resistant divergence mass" (sample
  size, threshold, how many model-version boundaries are needed).
- §a: whether the `otel-collector` file-exporter path earns its keep, or whether to
  wait for the team-stage engine (§b) instead.

## References

- PRD sections: D9 / W3 (§a); D8, Risks, Open questions "team-stage engine trigger"
  (§b); W4 -- Attribution (§c); Goals G3, W7 abstraction ladder (§d).
- Related: ADR-0002 (files-first, single-writer), ADR-0004 (counts-only invariant),
  ADR-0005 (attribution primary channel), RFC-0002 (correction mining feeds §d).
- External: the session manager's launch-composition step (§c); ClickStack docs; Apple
  `container` deferred-stage references (PRD appendix).
