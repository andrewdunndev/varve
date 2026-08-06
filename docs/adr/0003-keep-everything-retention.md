# ADR-0003 -- Keep everything: no TTL, no cull

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** operator + session

## Context

The historic record is the asset. The far-stretch goals (G3, G4) depend on long
history, and the correction signal (G2 / W7) is longitudinal -- its whole point is
recurrence across sessions and across model versions. Data thrown away is signal that
can never be recovered.

The record is already being deleted. Claude Code's `cleanupPeriodDays` defaults to 30
days; the current 782-file / 774 MB history is only what survived that window. Every
day left at the default loses more.

Two facts shape the response:

- **No disable sentinel exists.** Verified against the Claude Code settings
  documentation: `0` is rejected and the minimum is `1`. There is no "off." The
  supported way to approximate "never" is a large value.
- **Retention is nearly free at this scale.** zstd-compressed Parquet keeps the whole
  history in single-digit GB even under heavy multi-year projection (ADR-0002). There
  is no storage pressure to manage against.

Operator intent: "let it accumulate, I want to see what occurs." Decide a retention
policy, if any, only after the lake exists and its real growth is observed.

## Decision

- **No TTL, no cull, no hard cap in v1.**
- Set `cleanupPeriodDays` to `99999` (effectively-never) -- the max-value approach,
  since no disable sentinel exists.
- Disk safety is a single cheap tripwire: `just disk` reports lake size and warns at
  ~100 GB. Nearly moot at current scale; retained only as a guard against a runaway.
- Revisit retention only after the lake is in place and its growth is measured.

## Consequences

**Positive**
- The canonical source (ADR-0001) stops eroding; backfill captures maximal history.
- Longitudinal analyses -- correction durability across model-version boundaries -- have
  the data they require.

**Negative**
- Unbounded growth in principle. Bounded in practice by the scale finding and the
  tripwire.
- `cleanupPeriodDays=99999` is a workaround for a missing "disable" option. If Claude
  Code changes the setting's semantics or ceiling, revisit.

**Neutral**
- A real retention policy is deferred, not decided against. The tripwire is the only
  active control until growth data says otherwise.

## References

- PRD sections: D4; Day-one actions #1; W1 -- Lake foundation (`just disk`); Risks
  (disk growth).
- Related: ADR-0001 (transcripts canonical -- why the record matters), ADR-0002
  (Parquet + zstd make keep-everything cheap).
- External: Claude Code settings documentation (`cleanupPeriodDays`).
