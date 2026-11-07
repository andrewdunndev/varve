# Queries

Each file answers one question. Its header defines the metric and its caveats.
Run one with `just sql -f <path>`.

| Folder | File | Question |
|--------|------|----------|
| `queries/` | `burn_by_day.sql` | Where does spend and token burn go, by estate, harness, campaign, model and day? |
| `queries/` | `burn_cache_hit.sql` | How much of the attended input is served from cache? |
| `queries/` | `burn_model_mix.sql` | Is each estate's weekly model mix shifting toward cheaper tiers? |
| `queries/` | `dispatch_ratio.sql` | What share of a session's work is carried by subagents? |
| `queries/` | `model_economics.sql` | What does each model cost per session, and how cache-efficient is it? |
| `queries/` | `reconcile_ccusage.sql` | Do token totals match ccusage? |
| `queries/` | `reconcile_pi_cost.sql` | Does pi's inline cost match the computed cost? |
| `queries/` | `recycle.sql` | Do sessions stay under the recycle thresholds, and what do overruns cost? |
| `queries/` | `session_shape.sql` | What does a typical session look like, and which are the expensive outliers? |
| `queries/` | `subagent_economics.sql` | What do subagents cost against the main thread? |
| `queries/` | `tool_outcomes.sql` | How do tool calls end, by tool, and what do their arguments and results weigh? |
| `mining/queries/` | `adjudication_sample.sql` | Which correction candidates should be labelled for precision? |
| `mining/queries/` | `corrections_candidates.sql` | How many correction candidates did mining produce, by detector? |
| `mining/queries/` | `recall_floor_sample.sql` | How many corrections did mining miss? |
| `mining/queries/` | `stats_year.sql` | What did the year look like, one day per cell? |

Keep personal queries outside the repo and run them the same way.
