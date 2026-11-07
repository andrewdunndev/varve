# ADR-0005: Attribution by ingest-time cwd mapping, not launch-time env

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** maintainer

## Context

Every analysis slices by `harness`, `estate` and `campaign`, the three attribution
columns on `sessions` (defined in the PRD, Architecture): burn by campaign,
divergence by estate, dispatch shape by harness. Each session record needs those
three tags.

Two channels could supply them:

1. **Launch-time env.** Inject `OTEL_RESOURCE_ATTRIBUTES=harness=..,estate=..,campaign=..`
   into each session at launch, so the attributes propagate as labels. Whatever
   launches the session must set per-launch env, and no launcher in use does.
2. **Ingest-time cwd mapping.** Derive the tags from the transcript itself, by
   mapping the recorded working directory onto a known directory layout. A session
   starts in its project's directory, so the recorded path is a deterministic key.

The env channel has two disqualifying limits for v1: it only feeds the live plane
(deferred, D9), and it can only tag future sessions. It cannot attribute the
historical backfill, which is most of the value. The cwd mapping is deterministic,
retroactive, and covers all history.

## Decision

- Ingest-time cwd → harness/estate/campaign mapping is the primary channel, and in
  v1 the only one. The transcript adapter resolves each session's directory against
  a user-maintained mapping (`adapters/attribution.example.csv` is the template) and
  writes `harness`, `estate`, `campaign` onto the `sessions` row.
- The `OTEL_RESOURCE_ATTRIBUTES` env-injection design is deferred with the live
  plane. It blocks nothing in v1.

## Consequences

**Positive**
- Works on backfilled history; the env channel cannot.
- No dependency on an unshipped launcher feature and no coupling to the deferred
  live plane.
- One mapping in one place (the adapter), re-runnable if the directory layout
  changes.

**Negative**
- Depends on a maintained cwd → estate mapping table. Directories that do not match
  need an "unknown" bucket (RFC-0001).
- A session launched from an unusual working directory may misattribute until the
  mapping is extended.

**Neutral**
- The env channel remains the right approach for the live plane if it ever wakes.

## References

- PRD sections: Decisions (D5); Architecture.
- Related: ADR-0001 (the transcript is the source), RFC-0001 (mapping-table
  representation).
