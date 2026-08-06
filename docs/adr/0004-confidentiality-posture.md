# ADR-0004 -- Confidentiality posture: local-only, zero listeners, zero egress

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** operator + session

## Context

The operator's work involves confidential client contexts, so session records
contain client-confidential material. Confidentiality is the load-bearing
constraint. The operator's private estates must never surface in any committed
or published artifact.

varve makes full session *content* queryable, which raises the obvious question: does
a queryable content lake increase exposure? The answer is no, and the reason is the
core exposure argument: **the content already sits in `~/.claude` (and the other
runtimes' stores) on this disk.** The lake changes queryability, not exposure -- same
machine, same user, same bytes.

The pivot to a file-first engine (ADR-0002) then removed the last network surface:
with no server there is no listener at all, not even on localhost. The confidentiality
posture strictly improved relative to the original two-plane (transcript + OTLP)
design.

## Decision

Five invariants. Where any of them conflicts with a design choice, the invariant wins.

- **I1 (dormant in v1, retained).** If a telemetry plane is ever wired, every
  `OTEL_LOG_*` content flag stays OFF and the pipe carries counts/metadata only.
- **I2.** Content enters the system only via transcript ingest, only into the local
  Parquet lake, only from files already on this disk.
- **I3.** No listeners in v1. Zero egress. No cloud/SaaS backend. Any future listener
  (team stage) binds `127.0.0.1`.
- **I4.** The operator's private estates are never named in any committed or
  published artifact -- estate and client identifiers live outside the repo, in
  the data home. Benchmark synthesis (W6 v2) and any W7 publication are
  role-level abstractions -- no sector, account, research, or estate identifiers.
- **I5.** Correction-event content (model drafts, operator rewrites) is stored as
  local-only pointers (`model_draft_ptr`, `operator_rewrite_ptr`) and is never
  published verbatim.

**Two rulings on the correction-mining channel (W7):**

- **Third-party embedding APIs are excluded.** Work content must not be sent to an
  external embedding service. When semantic clustering graduates beyond
  LLM-assisted labeling, embeddings are generated locally (e.g. sentence-transformers
  via `uv`, model weights cached on disk). Embedding vectors of work content never
  leave the machine.
- **LLM-assisted labeling inside a harness session is acceptable.** It is the same
  exposure class as the sessions that produced the content -- it rides the same API
  path the operator already uses and opens no new data channel. This is the boundary:
  reusing the existing session API path is fine; introducing a new third-party data
  channel is not.

## Consequences

**Positive**
- No network attack surface in v1. The confidentiality story is testable and blunt:
  "nothing is bound." Verifiable by network capture and by checking for a listening
  socket.
- Clear rules rather than trust: the invariants are mechanical checks.

**Negative**
- Local embeddings add a dependency (`uv` + cached model weights) when clustering
  graduates -- accepted to preserve I3 and the API exclusion.
- LLM-assisted labeling inherits the existing API path's posture. If that path's
  guarantees change, this ruling must be revisited.

**Neutral**
- The dormant I1 keeps the telemetry option open without weakening v1.

## References

- PRD sections: Confidentiality invariants; D7; Non-goals; W7 -- Correction mining
  (clustering dependency, embeddings); Risks (confidentiality).
- Related: ADR-0001 (content enters via transcripts), ADR-0002 (no server = no
  listener), RFC-0002 (correction schema and local-only pointers), RFC-0004 §a
  (dormant telemetry plane).
