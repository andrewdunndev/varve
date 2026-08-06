# RFC-0003 -- Benchmark synthesis

- **Status:** draft
- **Date:** 2026-07-06

## Summary

Derive task-shape distributions from lake history, scrub all content, and synthesize
benchmark analogs that leak no sector, account, research, or estate identifiers
-- audited before use, and serving as the shared spine for the work harness's
context-economics benchmark. This is the W6 v2 design.

## Motivation

The operator wants a benchmark system that does not leak real work (the fourth ask
under goal G4). History is the richest available source of realistic task shapes, but
the confidentiality constraint (ADR-0004, invariant I4) forbids using it raw.
Synthesis is the bridge: keep the statistical shape, discard the content.

## Design

- **Input:** the lake (`sessions`, `messages`, `api_calls`, `tool_calls`), which
  already encodes real task shapes -- session length, tool mix, dispatch structure,
  model tier, turn counts.
- **Derive distributions, not instances.** Compute distributions over structural
  features with content stripped. The artifact is a set of shape distributions, not a
  sample of real tasks.
- **Generate analogs** from the distributions: synthetic tasks that match the
  statistical shape of real work but contain no real content.
- **Audit before use.** Every synthetic task is checked for the absence of client /
  sector / account / research / estate identifiers (ADR-0004 I4) before it enters a
  benchmark run.
- **Shared spine.** Feeds the context-economics campaign's benchmark-design note in
  the work harness.

**Relationship to the rest of W6.** v1 (cost counterfactuals + design priors) is plain
SQL over `api_calls` and is not RFC-worthy. v3 (the replay rig) is a go/no-go gate
only -- real spend and workload-fixity problems mean it is not committed; this RFC does
not design it. This RFC is v2 alone.

## Unresolved questions

- Abstraction fidelity vs leak risk: how close to real can a synthetic task be before
  it risks re-identifying real work? Where is the line drawn, and who draws it?
- Audit procedure: manual review, an automated scrub, or an LLM-assisted check -- and
  who signs off that a task is clean.
- Sufficient task-shape features: which structural features must be preserved for the
  benchmark to be useful, and which must be dropped for safety.

## References

- PRD sections: W6 -- Historic record → simulation + benchmarks (v2; with v1 and v3
  context).
- Related: ADR-0004 (invariant I4, role-level abstraction rule), ADR-0001 (the lake as
  input).
- External: the context-economics campaign's benchmark-design note (shared spine).
