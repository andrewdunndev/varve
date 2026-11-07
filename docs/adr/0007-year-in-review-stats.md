# ADR-0007: Year-in-review stats, metric definitions for `just stats`

- **Status:** accepted
- **Amended by:** ADR-0008 (the lake is built from the mirror, not ingested)
- **Date:** 2026-10-13
- **Deciders:** maintainer

## Context

`just stats` prints a year summary in the terminal: a GitHub-style activity heatmap plus a
few year totals. The lake carries what it needs (`sessions`, `messages`, `api_calls`,
`tool_calls` and the correction-mining `operator_messages` table), but "session", "prompt"
and "step" mean different things per runtime. Claude Code folds subagent transcripts into
the parent `session_id`, opencode chains child sessions through `parent_session_id`, and pi
writes no child transcript at all. Without fixed definitions the summary would count
differently each time it is read.

Timestamps differ too. Claude Code and pi store UTC. opencode stores wall-clock time in the
build's TimeZone, because the adapter casts `to_timestamp(ms)` to `TIMESTAMP`.

## Decision

The metrics are defined once, in `mining/queries/stats_year.sql` (its header carries the same
text). `mining/stats_render.sql` only lays them out.

- **session**: one top-level transcript: a `sessions` row with `parent_session_id` NULL,
  counted on its `started_at` day.
- **subagent**: one child transcript or sidechain. Claude Code: a sidechain root (an
  `is_sidechain` message with no `parent_id`). opencode: a session with `parent_session_id` set.
- **prompt**: one human-authored user turn: an `operator_messages` row (the correction-mining
  `is_operator` predicate, which excludes tool results and runtime-injected messages) that is
  neither a sidechain message nor in an opencode child session. The predicate is reused, not
  rewritten.
- **step**: one assistant turn: one `api_calls` row.
- **tokens**: `input + output + cache_read + cache_write`.
- **cost**: `sum(api_calls.cost_usd)`, as priced at build by the adapters and
  `pricing.toml`. Nothing is re-priced.
- **tool success**: tool results not marked as errors, divided by all tool results.
- **active day**: a local day with at least one prompt.
- **best streak**: the longest run of consecutive active days inside the window. A run that
  crosses Jan 1 is cut at the window edge.

Window and grid:

- The window runs from Jan 1 to the earlier of Dec 31 and today, in local time (the DuckDB
  `TimeZone`, from `TZ`). Each event lands on the local day of its own row timestamp, not the
  session-start partition. opencode timestamps are taken as already local.
- Rows are weekdays Mo to Su. Columns are Monday-start (ISO) weeks, from the week that holds
  Jan 1. Month labels sit on the column that holds the 1st of the month.
- Each cell's glyph is set by its `metric` (prompts, steps or tokens). An inactive day is `·`.
  Active days take `░▒▓█` by quartile of the metric over the window's active days, with
  `quantile_disc` thresholds so ties land in the same level.
- Future days are trimmed. The grid ends at the current week; the rest of that week, like
  the days before Jan 1 in the first column, is blank.

Per-runtime gaps. Where a runtime does not expose a field, it is reported as missing, not
invented:

| Metric | Claude Code | pi | opencode |
|--------|-------------|----|----------|
| subagent | sidechain roots | not exposed: `--no-session` children write no transcript (ADR-0006), so always 0 | child sessions, which mostly chain sessions rather than dispatch work, so the count reads high as a dispatch signal |
| prompt | `operator_messages`, minus sidechain rows | pi is absent from correction mining, so this falls back to `role='user'` messages with no injection filter | `operator_messages` in top-level sessions |
| step | one per `(message.id, requestId)` | one per assistant entry | one per assistant message; per-step `step-finish` parts are not in the lake |
| tokens | all four classes | all four classes | all four classes; `tokens.reasoning` is not in the lake |
| tool success | `tool_result` blocks, error = `is_error`, one per `tool_use_id` | `toolResult` entries, error = `isError` | `state.status` completed or error; `running` has no result and is excluded |

## Consequences

**Positive**
- A one-command summary with no new process, no listener and no egress: a read-only
  DuckDB session over the lake, using temp tables only.
- The definitions live in one query header and this record. The synthetic corpus pins
  them in `just test`: a rendered snapshot, a streak across the year boundary, an empty
  year and a runtime filter.

**Negative**
- Prompts depend on `operator_messages`, so `just mine` must have run. It runs inside
  every `just build`, after the swap.
- opencode's wall-clock timestamps are correct only when the build ran in the user's own
  time zone. Storing UTC there is an adapter change and needs a rebuild, so it is not
  made here.

**Neutral**
- The heatmap measures volume, not outcome. Tool success counts error flags only and
  cannot tell whether the work succeeded.

## References

- Goals: `docs/prd.md` (G1).
- Related: ADR-0006 (per-runtime gaps), `sql/record.sql` (the record contract), RFC-0002 (`operator_messages`), `docs/queries.md`.
