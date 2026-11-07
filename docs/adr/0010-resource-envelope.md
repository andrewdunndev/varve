# ADR-0010: Resource envelope

- **Status:** proposed
- **Date:** 2026-11-06
- **Deciders:** maintainer

## Context

- One DuckDB process ran 11.5 hours beside other agent sessions.
- It dirtied file-backed memory for hours, and the machine hung that night.
- `_pipeline` sets threads and a spill cap but no memory limit. Only `mine` has one.
- Defaults take most of the machine.

## Decision

- One wrapper, `bin/duck`, is the only path to DuckDB. It runs every SQL file: adapters, checks, mines and queries.
- It sets memory, threads, spill cap, low priority, a wall-clock limit, and a lock. Runs never stack.
- DuckDB does not promise `memory_limit` as a whole-process cap, so the wrapper also watches resident memory and kills the run over its cap.
- `just lint` fails on DuckDB anywhere else. `just test` goes through the wrapper.
- Defaults live in the wrapper, set from the first measured build. Env overrides them.
- On a bound: the process dies, `lake.new` goes, the published lake is untouched, exit 1, and one line names the next action.
- `sync` never opens DuckDB. It runs at low priority, one at a time, and ships only after the wrapper.
- A lab run forced over each cap proves it stops, before any run on a shared machine.
- Build runs on a host with headroom.

## Consequences

**Positive**
- A runaway run stops at its caps.

**Negative**
- Bounds are guesses until the first measured build.

## References

- Principles: Bundled enforcement, Prescriptive failure.
- Related: ADR-0008.
