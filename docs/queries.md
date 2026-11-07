# Queries

Each file in `queries/` answers one question. Its header holds the metric definition and the caveats.

| File | Question |
|------|----------|
| `adjudication_sample.sql` | Which correction candidates should be labelled for precision? |
| `burn_by_day.sql` | Where does spend and token burn go, by estate, harness, campaign, model and day? |
| `burn_cache_hit.sql` | How much of the attended input is served from cache? |
| `burn_model_mix.sql` | Is each estate's weekly model mix shifting toward cheaper tiers? |
| `corrections_candidates.sql` | How many correction candidates did mining produce, by detector? |
| `dispatch_ratio.sql` | What share of a session's work is carried by subagents? |
| `model_economics.sql` | What does each model cost per session, and how cache-efficient is it? |
| `recall_floor_sample.sql` | How many corrections did mining miss? |
| `reconcile_ccusage.sql` | Do token totals match ccusage? |
| `reconcile_pi_cost.sql` | Does pi's inline cost match the computed cost? |
| `recycle.sql` | Do sessions stay under the recycle thresholds, and what do overruns cost? |
| `session_shape.sql` | What does a typical session look like, and which are the expensive outliers? |
| `stats_year.sql` | What did the year look like, one day per cell? |
| `subagent_economics.sql` | What do subagents cost against the main thread? |

## Run one

```
just sql -f queries/burn_by_day.sql
```

## Run your own

Keep personal queries outside the repo and run them the same way.

```
just sql -f ~/path/to/my_query.sql
```
