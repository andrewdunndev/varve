-- QUESTION: A session that blows past the recycle threshold -- is that a genuine
--   efficiency problem, or is it coordinating dispatched work (and therefore fine)?
--   A recycle-threshold sweep found the sub-200K discipline fights real task shapes
--   (median session peaks can sit well past both candidate thresholds, and the
--   recoverable-spend upper bound roughly halves strict->loose). Reframe: a high threshold
--   (300K) is a REVIEW TRIGGER, not a cap, and only tells you something when paired
--   with the real lever -- dispatch. This query operationalizes that split as a
--   standing diagnostic.
-- METRIC: Per claude-code session: peak = max(input+cache_read) per call (the
--   effective-context definition shared by recycle.sql / counterfactual_recycle.sql);
--   cost_usd = sum(cost_usd); excess_usd = sum over the session's calls of
--   counterfactual_recycle.sql's per-call saving -- ctx_cost*(eff-t1)/eff where
--   ctx_cost = input*input_rate + cache_read*cache_read_rate at the call's OWN model
--   rates (0 when eff<=t1) -- i.e. the dollar upper bound recoverable by holding this
--   session at t1 (same formula, reused verbatim, rolled up to session grain instead
--   of estate x month). dispatch_share_calls / dispatch_share_cost = sidechain share
--   of the session's calls/cost (dispatch_ratio.sql's is_sidechain definition).
--   opus_call_share = share of the session's calls on the opus tier
--   (model_economics.sql tiering CASE) -- the model-mix signal. t1 defaults to 300000
--   (see ASSUMPTIONS); override with
--     just sql -c "SET VARIABLE t1='250000'" -f queries/fat_inline.sql
-- CLASSIFICATION:
--   'fat_inline'       = peak > t1 AND dispatch_share_calls <  EPS
--   'coordinated_deep' = peak > t1 AND dispatch_share_calls >= EPS
--   'under_threshold'  = peak <= t1
--   EPS = 0.02 (sidechain calls below 2% of a session's calls counts as "no
--   dispatch"). Not zero: a single incidental subagent call (one stray Explore) is
--   noise, not coordination -- EPS keeps that from flipping a session's label off a
--   single call the way an exact ">0" test would.
-- SCOPE: claude-code ONLY, per dispatch_ratio.sql's SCOPE decision (coordinator
--   2026-07-06): is_sidechain is the only real dispatch marker in the lake --
--   opencode carries zero is_sidechain=true rows across its messages (its
--   parent_session_id is a session-chain link, not delegation) and pi has neither
--   sidechain nor populated child linkage. Scoring those runtimes against a dispatch
--   epsilon would read every peak-heavy session as 'fat_inline' by DATA GAP, not by
--   behavior -- not this query's claim. Revisit if either runtime grows a real
--   dispatch marker (dispatch_ratio.sql SCOPE note).
-- ASSUMPTIONS (excess_usd is an UPPER BOUND -- counterfactual_recycle.sql's caveats
--   apply unchanged, now per-session rather than per-estate-month):
--   * Does NOT model re-orientation cost -- a recycled session must re-read the
--     context it dropped, and that re-read is not free.
--   * Does NOT model output-token changes -- only the input+cache_read excess is
--     repriced; output/cache_write cost is held fixed.
--   * Assumes work quality is unaffected by running leaner.
--   * t1 defaults to 300000, not recycle.sql's 120K/180K redline: this is the
--     REVIEW-TRIGGER reframe from the sweep -- sub-200K discipline fights real task
--     shapes, and savings taper hard past 120K (roughly halving by 300K), so 300K
--     is where "check what this session was doing" starts paying for itself.
--     Crossing t1 is a prompt to check dispatch, not an automatic verdict.
--   * The classification is a HEURISTIC on one session's shape, not a quality
--     judgment: 'coordinated_deep' sessions can still be run inefficiently, and a
--     'fat_inline' session may have been the right call for its task (e.g. a single
--     large read that genuinely had no dispatchable sub-unit).
-- CAVEATS: PER-CALL context, not the harness UI counter (recycle.sql caveat).
--   Unpriced (subscription-billed, $0) calls contribute zero excess by construction. wall_min is
--   elapsed time from message timestamps (session_shape.sql caveat: includes idle
--   gaps, not active time). Console authoritative on absolute cost. TEMP tables are
--   in-memory (no lake write; read-only safe).
-- Recycle-threshold diagnostic. Run: just sql -f queries/fat_inline.sql
CREATE TEMP TABLE per_call AS
  WITH thr AS (
    SELECT coalesce(try_cast(getvariable('t1') AS BIGINT), 300000) AS t
  ),
  price AS (
    SELECT model, input_cost, cache_read_cost
    FROM read_csv(coalesce(getvariable('repo'), '.') || '/adapters/pricing.csv',
                  header = true, comment = '#', auto_detect = true)
  )
  SELECT
    a.runtime,
    a.session_id,
    s.estate,
    (a.input + a.cache_read)                                        AS eff,
    a.cost_usd,
    (a.input      * coalesce(p.input_cost, 0)
   + a.cache_read * coalesce(p.cache_read_cost, 0))                 AS ctx_cost,
    (SELECT t FROM thr)                                             AS t,
    coalesce(m.is_sidechain, false)                                 AS is_subagent,
    (a.model LIKE 'claude-opus%')                                   AS is_opus
  FROM api_calls a
  JOIN sessions s USING (runtime, session_id)
  LEFT JOIN price p USING (model)
  LEFT JOIN messages m
    ON m.runtime    = a.runtime
   AND m.session_id = a.session_id
   AND m.message_id = a.message_id
  WHERE a.runtime = 'claude-code';

CREATE TEMP TABLE per_session AS
  SELECT
    runtime,
    session_id,
    any_value(estate)                                               AS estate,
    any_value(t)                                                    AS t,
    count(*)                                                        AS calls,
    max(eff)                                                        AS peak,
    round(sum(cost_usd), 2)                                         AS cost_usd,
    round(sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END), 2)
                                                                     AS excess_usd,
    round(count(*) FILTER (WHERE is_subagent) / count(*)::double, 4) AS dispatch_share_calls,
    round(sum(cost_usd) FILTER (WHERE is_subagent)
        / nullif(sum(cost_usd), 0), 4)                              AS dispatch_share_cost,
    round(count(*) FILTER (WHERE is_opus) / count(*)::double, 4)    AS opus_call_share
  FROM per_call
  GROUP BY runtime, session_id;

CREATE TEMP TABLE classified AS
  SELECT
    *,
    CASE
      WHEN peak > t AND dispatch_share_calls < 0.02 THEN 'fat_inline'       -- EPS, see header
      WHEN peak > t AND dispatch_share_calls >= 0.02 THEN 'coordinated_deep'
      ELSE 'under_threshold'
    END                                                              AS classification
  FROM per_session;

CREATE TEMP TABLE wall AS
  SELECT session_id,
         round(date_diff('second', min(timestamp), max(timestamp)) / 60.0, 1) AS wall_min
  FROM messages
  WHERE runtime = 'claude-code'
  GROUP BY session_id;

-- (1) summary: sessions, cost, savable excess by classification x estate
SELECT
  classification,
  estate,
  count(*)                                                          AS sessions,
  round(sum(cost_usd), 2)                                           AS total_cost_usd,
  round(sum(excess_usd), 2)                                         AS total_excess_usd
FROM classified
GROUP BY ALL
ORDER BY total_excess_usd DESC, classification, estate;

-- (2) top 25 fat_inline sessions, ranked by savable excess
SELECT
  c.runtime,
  c.session_id,
  c.estate,
  c.peak,
  c.cost_usd,
  c.excess_usd,
  c.dispatch_share_calls,
  w.wall_min
FROM classified c
LEFT JOIN wall w USING (session_id)
WHERE c.classification = 'fat_inline'
ORDER BY c.excess_usd DESC
LIMIT 25;
