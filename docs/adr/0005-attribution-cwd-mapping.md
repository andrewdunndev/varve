# ADR-0005 -- Attribution by ingest-time cwd mapping, not launch-time env

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** operator + session

## Context

Every analysis must slice by harness, estate, and campaign: burn by campaign,
divergence by estate, dispatch shape by harness. So each session record needs those
three tags.

Two channels could supply them:

1. **Launch-time env.** Inject `OTEL_RESOURCE_ATTRIBUTES=harness=..,estate=..,campaign=..`
   into each session at launch, so the attributes propagate as labels. This needs the
   session manager to set per-launch env -- an upstream feature that does not yet
   exist.
2. **Ingest-time cwd mapping.** Derive the tags from the transcript itself, by mapping
   the recorded working directory / project path onto the known estate layout. The
   session manager launches each session with the campaign directory as its cwd, so
   the recorded path is a deterministic key.

The env channel has two disqualifying limits for v1: it only feeds the *live plane*
(deferred -- D9 / W3), and it can only tag *future* sessions. It cannot attribute the
historical backfill, which is most of the value. The cwd mapping is deterministic,
retroactive, and covers all history.

## Decision

- **Ingest-time cwd → harness/estate/campaign mapping is the primary channel, and in
  v1 the only one.** The transcript adapter resolves each session's directory against
  the estate layout and writes `harness`, `estate`, `campaign` onto the `sessions`
  row.
- The session-manager `OTEL_RESOURCE_ATTRIBUTES` env-injection design is
  documented-for-later (RFC-0004 §c). It is not a blocker for anything in v1.

## Consequences

**Positive**
- Works on backfilled history -- the env channel cannot.
- No dependency on an unshipped session-manager feature and no coupling to the
  deferred live plane.
- One mapping in one place (the adapter), re-runnable retroactively if the estate
  layout changes.

**Negative**
- Depends on a maintained cwd → estate mapping table. Directories that do not match
  need a fallback / "unknown" bucket (representation is an RFC-0001 open question).
- A session launched from an unusual working directory may misattribute until the
  mapping is extended.

**Neutral**
- The env channel remains the right approach for the live plane if and when it wakes
  (RFC-0004 §c).

## References

- PRD sections: D5; W4 -- Attribution.
- Related: ADR-0001 (transcript plane is the source), RFC-0001 (mapping-table
  representation), RFC-0004 §c (session-manager per-launch env, deferred).
