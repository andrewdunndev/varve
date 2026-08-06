# varve query library (W5)

Versioned cost + efficiency queries over the Parquet lake. One file per question in
`queries/`; each file's header states the QUESTION, the METRIC DEFINITION (in lake
columns), and CAVEATS. Run read-only: `just sql -f queries/<file>.sql`. The engine is
attached read-only, so a lake/db write fails loudly (verified); the multi-result-set
queries build in-memory TEMP tables only.

Definitions below are the metric definitions from each file's header (kept in sync).

| File | Question | Metric definition (summary) |
|------|----------|-----------------------------|
| `burn_by_day.sql` | Where does spend/token burn go by estate/harness/campaign/model/day? | Per (estate, harness, campaign, model, day): calls; sum of each token class; sum(cost_usd). Day = `api_calls.timestamp::date` (row, not partition). Attribution from `sessions`. |
| `burn_cache_hit.sql` | How cache-read-dominated is burn, by model and by day? | `cache_hit_ratio = sum(cache_read)/nullif(sum(cache_read)+sum(input),0)`; plus `cache_read:input` ratio. Reported by model and by day. `cache_write` excluded from denominator. |
| `burn_model_mix.sql` | How is each estate's weekly spend split across models? | Per (estate, week, model): `model_cost = sum(cost_usd)`; `cost_share = model_cost / sum(model_cost) OVER (estate, week)`. week = `date_trunc('week', timestamp)`. |
| `dispatch_ratio.sql` | Coordinate-by-default adherence: subagent vs main-thread share? | Claude Code ONLY. Dispatch unit = session; subagent = `is_sidechain=true`. `share_X = subagent_X/total_X` for calls/tokens/cost. Weekly trend + FAT-INLINE flag (cost >= threshold, default $20, and zero subagent traffic). opencode/pi excluded -- no real dispatch marker (see below). |
| `recycle.sql` | Context discipline: do calls run over the 120K/180K redline, and what does it cost? | Effective context/call = `input + cache_read`. Per session: `max_eff_ctx`; `pct_over_t1`/`pct_over_t2` = share of calls above each threshold (defaults 120K/180K); `redline_cost_usd` = sum(cost_usd) of calls above 120K. Per-estate p50/p90/max + redline share. Thresholds parameterized. |
| `session_shape.sql` | What is a typical session's shape; which are the expensive outliers? | Per session: `n_calls`; `wall_min` = `date_diff('second', min, max)` over messages /60; `cost_usd`. Per (estate, runtime) p50/p90/max of each; top-20-by-cost leaderboard with harness/campaign. |
| `model_economics.sql` | Cost/session and cache efficiency by model; who runs cheap vs never leaves opus? | Per model: sessions, calls, cost, `cost_per_session`, `avg_cost_per_call`, `cache_hit_ratio`. Per (harness, campaign): `opus_cost_share`, `cheap_call_share` (sonnet/haiku), `duo_call_share`. Tier by model-name prefix. |
| `subagent_economics.sql` | For CC, what do sidechains cost vs main thread over time? | CC only. Sidechain = message `is_sidechain=true`. Per week: `main_cost`/`sub_cost`, `sub_cost_share`, `sub_call_share`, tokens by role, `cache_read:input`. ROLLUP totals row. |
| `corrections_candidates.sql` (W7) | How many correction candidates per detector/day/estate; is the lexical marker list too loose? | count of `correction_candidates` rows per detector x {runtime, day, estate/harness}. Volume-sanity gate: lexical hits as a % of a runtime's user messages, flagged if > 5%. Pre-adjudication (volume, not precision). |
| `adjudication_sample.sql` (W7) | The stratified sample the operator adjudicates for G-precision. | Up to 50 candidates per detector ("50 or all"), deterministic sample (`ORDER BY md5(candidate_id)`). Emits loci (`lake:` form), model_id, attribution, features, a truncated corrective-message EXCERPT, and a fill-in JSONL skeleton. Fabricates no precision numbers. |
| `recall_floor_sample.sql` (W7) | Of operator messages mining did NOT flag, what fraction are missed corrections -- the G-recall floor? | 50 rows from `operator_messages` WHERE `flagged=false`, deterministic sample (`ORDER BY md5(message_uuid)`); zero overlap with `correction_candidates` by construction. Emits loci, attribution, a truncated EXCERPT, and a fill-in JSONL skeleton keyed on `message_uuid` with `"selection":"sampled"`. |

## Conventions

- **Parameterization.** Threshold queries read a DuckDB variable with a default via
  `coalesce(try_cast(getvariable('x') AS ...), default)`. Override by setting the
  variable *before* the file (the `-c` runs before the `-f`), e.g.
  `just sql -c "SET VARIABLE fat_threshold='50'" -f queries/dispatch_ratio.sql`.
- **Cost.** `cost_usd` is computed from tokens x the pricing seed (`costUSD` is absent
  from the corpus, RFC-0001); the console is authoritative. GitLab-Duo subscription
  models (opencode) are genuinely $0 and carry calls/tokens but no cost.
- **tokens** where used unqualified = `input+output+cache_read+cache_write` (all four
  classes) and is cache_read-dominated, so cost shares are more load-bearing than
  token shares.

## Resolved definition (coordinator decision 2026-07-06)

`dispatch_ratio.sql` was specified to count opencode children (`parent_session_id`
set) as subagent traffic; the data showed that link is session CHAINING, not
dispatch: 1318/1626 opencode sessions are children yet carry only ~6% of opencode
priced cost, and the true `agent` marker is populated on just 2 rows. Decision:
the adherence metric is Claude Code only (`is_sidechain`); opencode and pi are
excluded until either grows a real dispatch marker. The clean adherence signal
pairs `dispatch_ratio.sql` with `subagent_economics.sql`.

## W6 v1 -- counterfactuals + design priors

The G4 counterfactual + design-prior slice (PRD W6 v1). Per RFC-0003 this is plain
SQL over `api_calls` -- NOT benchmark synthesis: nothing is generated and no content
leaves the machine. v2 (generating synthetic task shapes from the design priors)
stays GATED on RFC-0003's open questions; these files only produce the inputs.

| File | Question | Metric definition (summary) |
|------|----------|-----------------------------|
| `counterfactual_recycle.sql` | What could the redline tax have been worth? | For calls whose effective context (input+cache_read) exceeds the hold threshold `t1` (default 120000, recycle.sql's redline), the EXCESS = eff-t is repriced to zero at the call's OWN model input/cache-read rates: `saving = (input*input_rate + cache_read*cache_read_rate) * (eff-t)/eff` (proportional allocation of the excess across input+cache_read; output and cache_write untouched). Counterfactual = actual - saving. Reported by estate x month and total; saving as a share of total priced spend. `t1` overridable. |
| `counterfactual_tier.sql` | What tier-routing headroom exists? | Two STRUCTURAL Claude Code classes repriced at a cheaper tier (rates read from `adapters/pricing.csv`): (a) `is_sidechain` opus -> sonnet-class (claude-sonnet-5); (b) main-thread fable -> opus-class (claude-opus-4-8, since fable is priced 2x opus). Per class: calls, actual cost, repriced cost, delta, delta as share of total spend. |
| `design_priors.sql` | What content-free shape distributions parameterize a future benchmark? | Per (estate, runtime): p50/p90/max of session turns, api_calls/session, tool_calls/session, wall_min; effective-context trajectory (start/median/peak per session); tool-name mix shares; model-tier call/cost mix; Claude Code sidechain call/cost share. Aggregates only -- zero content. |

**Pricing reads.** `counterfactual_recycle.sql` and `counterfactual_tier.sql` read
per-token rates from `adapters/pricing.csv` the way the adapters do (`read_csv(...,
comment='#')`), resolving the path via `coalesce(getvariable('repo'), '.')` -- so a
plain `just sql -f queries/<file>.sql` from the repo root resolves it against the
working directory, and setting `repo` (as `just recon-pi` does) also works. No prices
are hardcoded; unpriced (Duo $0) models carry no rate and contribute no delta.

**Assumption blocks** (each file's header carries the full text; the load-bearing line):
- `counterfactual_recycle.sql` -- UPPER BOUND: it does not model the re-orientation
  cost of recycling (a fresh session must re-read the dropped context), holds
  output/cache_write cost fixed, and assumes work quality is unaffected. The
  context-economics campaign owns turning the bound into a target.
- `counterfactual_tier.sql` -- HEADROOM, not a claim: repricing assumes equal token
  counts and equal outcome quality; it is the price gap IF the cheaper tier did the
  identical work, not a claim it would succeed. The W5 finding that cheap tiers are
  ~0.7% of spend is the adoption baseline.
- `design_priors.sql` -- the W6 v2 input (RFC-0003); v2 generation stays gated. ZERO
  content: no message text, cwd, or session_id in any output row -- estate/runtime
  (+ tool_name or tier) aggregates only.

## context-economics campaign -- fat-inline diagnostic

The recycle-threshold sweep found sub-200K discipline fights real task shapes
(the author's median session peak sits well past both candidate thresholds;
the recoverable-spend upper bound roughly halves strict->loose, about $3,100
vs $1,450 per $10K of model spend -- measured proportions on a round
hypothetical, absolute totals deliberately unpublished). Reframe: a peak above `t1` is a REVIEW TRIGGER, not a verdict --
it only means something once you check whether the session dispatched.
`fat_inline.sql` makes that check standing.

| File | Question | Metric definition (summary) |
|------|----------|-----------------------------|
| `fat_inline.sql` | Did a peak-context session dispatch, or run everything inline? | Claude Code only (`dispatch_ratio.sql`'s SCOPE). Per session: `peak` = max(input+cache_read); `excess_usd` = `counterfactual_recycle.sql`'s per-call saving formula summed to session grain; `dispatch_share_calls`/`_cost` = sidechain share (`dispatch_ratio.sql`); `opus_call_share` = tier mix (`model_economics.sql` tiering). Classifies `fat_inline` (peak > `t1`, dispatch_share_calls < 0.02) vs `coordinated_deep` (peak > `t1`, share >= 0.02) vs `under_threshold`. `t1` defaults to 300000 (review-trigger, not `recycle.sql`'s redline). Summary by classification x estate, plus top-25 `fat_inline` leaderboard by `excess_usd`. |

- `fat_inline.sql` -- same UPPER BOUND caveats as `counterfactual_recycle.sql` (no
  re-orientation cost, output/cache_write held fixed, quality assumed unaffected).
  EPS = 0.02 on `dispatch_share_calls`: one incidental subagent call shouldn't flip
  a session's label. Claude Code only -- opencode carries zero `is_sidechain=true`
  rows and pi has no dispatch marker either, so scoring them would read as
  fat_inline by data gap, not behavior.

## W7 -- correction mining

`correction_candidates` / `operator_messages` / `correction_events` are produced by `just
mine` (runs inside every `just ingest`/`backfill`; `adapters/corrections.sql`), not by
these query files -- the queries only read them. `corrections_candidates.sql` is
content-free. `adjudication_sample.sql` emits a truncated content EXCERPT of each
corrective message for adjudication ergonomics: the excerpt is **lake-local only** --
computed at query time and printed to the terminal, never written to a repo file (the
`.sql` itself holds zero transcript content) and never exported off `~/.local/share/varve`.
Do not redirect its output into the repo. The corrected DRAFT is left as a locus
(`draft_locus`) to dereference live, not excerpted.

The adjudication ledger the sample feeds lives OUTSIDE the repo at a configured path
(`VARVE_ADJUDICATIONS`, default `<data_home>/adjudications.jsonl`; public-instrument rule
-- operator data never in git). Line format: RFC-0002 (Adjudication section).

`operator_messages` is the RFC-0002 G-recall-floor denominator: one row per genuine
operator message (metadata only -- no content), `flagged` true iff that message is also a
`correction_candidates` locus under any detector. `recall_floor_sample.sql` samples
`flagged=false` rows the same way `adjudication_sample.sql` samples candidates, so the
same adjudication loop measures what mining misses, not just what it catches.

**Intervention timeline (durability test).** `just interventions <rulebook_dir>` recovers
the RFC-0002 durability-test input -- bake dates -- from a rulebook's own git history,
with no new capture surface: each commit that touched the rulebook is one intervention,
its committer date is the bake date, and each file it touched is one row (a commit
touching N rule files yields N rows). It is a generic instrument: `rulebook_dir` is
whatever git repo the operator points it at (their voicing/rules directory, e.g.) --
nothing in this repo names that path. It only reads (`git -C <dir> log`); it never writes
to the rulebook, so it is safe to run against a dirty working tree. It writes
`<data_home>/state/interventions.csv` (`intervention_ref`, `bake_date`, `rule_path`,
`subject`) as a full rewrite every run (idempotent). This CSV is an analysis INPUT, not a
lake table -- nothing joins it automatically yet; that join (mined event dates against
rule commit dates -> `recurred_after_bake`) is phase-3 work per RFC-0002.

**Review document (`just review`).** The adjudication review sitting. Where
`adjudication_sample.sql` prints a 240-char excerpt per candidate to the terminal,
`just review` renders a full-context markdown document to `<data_home>/review_round1.md`
(override with `out=`) -- one section per flagged correction candidate carrying the
candidate_id, detector, non-identifying `lake:` loci, model_id/attribution/features, the
FULL prior assistant draft, the FULL corrective operator message, and a pre-formed
one-line JSONL skeleton to copy into the adjudications ledger. The round-0 finding
motivates it: `context_judgment` is largely un-inferable from a truncated excerpt, so the
review dereferences the whole loci. Each section also shows the model's advisory
suggestion (`suggested_verdict` / `suggested_context_judgment` / `rationale`) read from a
worksheet (`VARVE_WORKSHEET`, default `<data_home>/adjudication_worksheet.jsonl`) via
`read_json_auto` and clearly marked ADVISORY, NOT a verdict; the worksheet is operator
data outside the repo and its absence is non-fatal (the advisory degrades to "none").
Candidates ordered by detector then candidate_id. A second part appends the recall-floor
sample -- a deterministic 50 unflagged operator messages (same md5 order as
`recall_floor_sample.sql`) with `message_uuid`-keyed skeletons fixing `"selection":"sampled"`.
Loci already present in the adjudications ledger are SKIPPED, so the document shrinks as
the operator works through it (idempotent re-render). Implemented as `adapters/review.sql`
(the `mise exec -- duckdb :memory:` + COPY idiom, like `mine`). CONFIDENTIALITY: the ONLY
output is the markdown under the data home -- `adapters/review.sql` holds zero transcript
content, content is dereferenced from the local lake at run time, loci are the `lake:`
form, and nothing is printed to a terminal. Do not point `out=` off the data home.

## Pre-existing (W1/W2, not W5)

`reconcile_ccusage.sql` (per-model totals vs `ccusage`) and `reconcile_pi_cost.sql`
(pi inline-vs-seed cost) are reconciliation gates from W1/W2, retained here.
