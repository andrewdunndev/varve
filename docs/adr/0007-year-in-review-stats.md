# ADR-0007 -- Year-in-review stats: metric definitions for `just stats`

- **Status:** accepted
- **Date:** 2026-10-13
- **Deciders:** operator + session

## Context

The operator wants an opencode-stats-style year summary: a GitHub-style activity
heatmap plus a few year totals, printed in the terminal. The lake already carries
everything it needs (`sessions`, `messages`, `api_calls`, `tool_calls`, and the W7
`operator_messages` table), but words like "session", "prompt" and "step" mean
different things in each runtime. Claude Code folds subagent transcripts into the
parent `session_id`, opencode chains child sessions through `parent_session_id`, and
pi writes no child transcript at all. A summary with no fixed definitions would count
differently each time it is read.

Two facts about timestamps also shape the result. Claude Code and pi timestamps are
stored as UTC. opencode timestamps are stored as wall-clock time in the ingest run's
TimeZone, because the adapter casts `to_timestamp(ms)` to `TIMESTAMP`.

## Decision

We define the metrics once, in `queries/stats_year.sql` (its header carries the same
text). `sql/stats_render.sql` only lays them out.

- **session**: one top-level transcript, i.e. a `sessions` row with
  `parent_session_id` NULL, counted on its `started_at` day.
- **subagent**: one child transcript or sidechain. For Claude Code, a sidechain root
  (an `is_sidechain` message with no `parent_id`). For opencode, a session with
  `parent_session_id` set.
- **prompt**: one human-authored user turn. This is an `operator_messages` row (the
  W7 `is_operator` predicate, which excludes tool results and harness injections)
  that is neither a sidechain message nor in an opencode child session. We reuse that
  predicate and do not write a second one.
- **step**: one assistant turn, i.e. one `api_calls` row.
- **tokens**: `input + output + cache_read + cache_write`.
- **cost**: `sum(api_calls.cost_usd)`, as priced at ingest by the adapters and
  `adapters/pricing.csv`. Nothing is re-priced.
- **tool success**: tool results not marked as errors, divided by all tool results.
- **active day**: a local day with at least one prompt.
- **best streak**: the longest run of consecutive active days inside the window. A
  run that crosses Jan 1 is cut at the window edge.

Window and grid:

- The window runs from Jan 1 to the earlier of Dec 31 and today, in local time (the
  DuckDB `TimeZone`, from `TZ`). Each event lands on the local day of its own row
  timestamp, not on the session-start partition. opencode timestamps are taken as
  already local.
- Rows are weekdays Mo to Su. Columns are Monday-start (ISO) weeks, from the week
  that holds Jan 1. Month labels sit on the column that holds the 1st of the month.
- Each cell's glyph is set by its `metric` (prompts, steps or tokens). An inactive
  day is `·`. Active days take `░▒▓█` by quartile of the metric over the window's
  active days. We use `quantile_disc` thresholds rather than `ntile`, so ties land in
  the same level.
- Future days are trimmed. The grid ends at the current week, and the rest of that
  week, like the days before Jan 1 in the first column, is left blank.

Per-runtime gaps. Where a runtime does not expose a field, we report it as missing and
do not invent it:

| Metric | Claude Code | pi | opencode |
|--------|-------------|----|----------|
| subagent | sidechain roots | **not exposed**: `--no-session` children write no transcript (ADR-0006), so always 0 | child sessions; `docs/queries.md` notes these mostly chain sessions rather than dispatch work, so the count reads high as a dispatch signal |
| prompt | `operator_messages`, minus sidechain rows | pi is absent from W7 mining, so this falls back to `role='user'` messages with **no injection filter** | `operator_messages` in top-level sessions |
| step | one per `(message.id, requestId)` | one per assistant entry | one per assistant message; per-step `step-finish` parts are not in the lake |
| tokens | all four classes | all four classes | all four classes; `tokens.reasoning` is **not in the lake** |
| tool success | `tool_result` blocks, error = `is_error`, one per `tool_use_id` | `toolResult` entries, error = `isError` | `state.status` completed or error; `running` has no result and is excluded |

## Consequences

**Positive**
- A one-command summary (`just stats`) with no new process, no listener and no
  egress. It is a read-only DuckDB session over the lake, using temp tables only.
- The definitions live in one query header and this record, and the synthetic
  corpus pins them in `just test`: a rendered snapshot, a streak that crosses the
  year boundary, an empty year and a runtime filter.

**Negative**
- Prompts depend on `operator_messages`, so `just mine` must have run. It runs inside
  every `ingest` and `backfill`.
- opencode's local-wall-clock timestamps are correct only when the ingest ran in the
  operator's own time zone. Storing UTC there is an adapter change and needs a
  backfill, so it is not made here.

**Neutral**
- The heatmap measures volume, not outcome. Tool success counts error flags only and
  cannot tell whether the work succeeded.

## References

- PRD sections: W5 -- Cost + efficiency analytics (presentation layer).
- Related: ADR-0006 (per-runtime gaps), RFC-0001 (lake schema, timestamps, subagent
  traffic), RFC-0002 (`operator_messages`), `docs/queries.md`.
