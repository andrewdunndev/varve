# ADR-0003: Keep everything, no TTL, no cull

- **Status:** accepted
- **Amended by:** ADR-0008 (keep-everything binds the mirror)
- **Date:** 2026-07-06
- **Deciders:** maintainer

## Context

The historic record is the asset. The far goals in `docs/prd.md` depend on long history,
and the correction signal is longitudinal: its whole point is recurrence across
sessions and across model versions. Data thrown away is signal that can never be
recovered.

The record is already being deleted. Claude Code's `cleanupPeriodDays` defaults to
30 days, so only the last 30 days of transcripts survive at the default. Every day
left there loses more.

Two facts shape the response:

- No disable sentinel exists. The Claude Code settings documentation rejects `0` and
  sets the minimum at `1`. There is no "off". The supported way to approximate
  "never" is a large value.
- Retention is nearly free at this scale. zstd-compressed Parquet keeps a single
  user's whole history in single-digit GB even under heavy multi-year projection
  (ADR-0002). There is no storage pressure to manage against.

Decide a retention policy, if any, only after the lake exists and its real growth is
observed.

## Decision

- No TTL, no cull, no hard cap in v1.
- Set `cleanupPeriodDays` to `99999` (effectively never), since no disable sentinel
  exists.
- Disk safety is one cheap tripwire: `just disk` reports lake size and warns at
  ~100 GB. Nearly moot at this scale; retained as a guard against a runaway.
- Revisit retention only after the lake is in place and its growth is measured.

## Consequences

**Positive**
- The source (ADR-0001) stops eroding; backfill captures maximal history.
- Longitudinal analyses (correction durability across model-version boundaries)
  have the data they require.

**Negative**
- Unbounded growth in principle. Bounded in practice by the scale finding and the
  tripwire.
- `cleanupPeriodDays=99999` is a workaround for a missing "disable" option. If
  Claude Code changes the setting's semantics or ceiling, revisit.

**Neutral**
- A real retention policy is deferred, not decided against. The tripwire is the only
  active control until growth data says otherwise.

## References

- Related: ADR-0001 (why the record matters), ADR-0002 (Parquet + zstd make
  keep-everything cheap).
- External: Claude Code settings documentation (`cleanupPeriodDays`).
