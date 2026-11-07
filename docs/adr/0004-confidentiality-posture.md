# ADR-0004: Confidentiality posture (local-only, zero listeners, zero egress)

- **Status:** accepted
- **Amended by:** ADR-0008 (I2 wording: the mirror holds transcripts too)
- **Date:** 2026-07-06
- **Deciders:** maintainer

## Context

Session records can hold private material. Privacy is the load-bearing constraint:
nothing private, and nothing that identifies the user's projects or the people
behind them, may appear in a committed or published artifact.

varve makes full session content queryable. Does a queryable content lake increase
exposure? No. The content already sits in `~/.claude` and the other runtimes' stores
on the same disk. The lake changes queryability, not exposure: same machine, same
user, same bytes.

The file-first engine (ADR-0002) removed the last network surface. With no server
there is no listener at all, not even on localhost.

## Decision

Five invariants. Where one conflicts with a design choice, the invariant wins.

- **I1 (dormant in v1, retained).** If a telemetry plane is ever wired, every
  `OTEL_LOG_*` content flag stays OFF and the pipe carries counts and metadata only.
- **I2.** Content enters the system only via transcript ingest, only into the local
  Parquet lake, only from files already on this disk.
- **I3.** No listeners in v1. Zero egress of session data. No cloud or SaaS backend. Any future
  listener (team stage) binds `127.0.0.1`. One exception: the opencode adapter's
  `INSTALL sqlite` downloads the extension from DuckDB's extension host when it is not
  already installed; no session data goes with it.
- **I4.** The user's private estates and projects are never named in any committed
  or published artifact. Their identifiers live outside the repo, in the data home.
  Benchmark synthesis and any published correction-mining result are role-level
  abstractions with no identifying detail.
- **I5.** Correction-event content (model drafts, user rewrites) is stored as
  local-only pointers (`draft_ref`, `rewrite_ref`) and is never
  published verbatim.

Two rulings on the correction-mining channel:

- **Third-party embedding APIs are excluded.** Session content is never sent to an
  external embedding service. When semantic clustering outgrows LLM-assisted
  labeling, embeddings are generated locally (for example sentence-transformers via
  `uv`, model weights cached on disk). Embedding vectors of session content never
  leave the machine.
- **LLM-assisted labeling inside an agent session is acceptable.** It is the same
  exposure class as the sessions that produced the content: it rides the API path
  the user already uses and opens no new data channel. The boundary: reusing the
  existing session API path is fine; a new third-party data channel is not.

## Consequences

**Positive**
- No network attack surface in v1. The claim is testable and blunt: nothing is
  bound. Verifiable by network capture and by checking for a listening socket.
- Rules, not trust: the engine-name invariant is a lint; the others rest on review.

**Negative**
- Local embeddings add a dependency (`uv` plus cached model weights) when clustering
  graduates. Accepted, to preserve I3 and the API exclusion.
- LLM-assisted labeling inherits the existing API path's posture. If that path's
  guarantees change, revisit this ruling.

**Neutral**
- The dormant I1 keeps the telemetry option open without weakening v1.

## References

- PRD sections: Confidentiality invariants; Decisions (D7); Non-goals; Risks.
- Related: ADR-0001 (content enters via transcripts), ADR-0002 (no server means no
  listener), RFC-0002 (correction schema and local-only pointers).
