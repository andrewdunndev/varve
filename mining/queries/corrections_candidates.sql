-- QUESTION: How many correction candidates did mining produce, sliced by detector,
--   runtime, day, and estate/harness -- and does any detector's volume look wrong?
-- METRIC: count of correction_candidates rows (one row per detector+locus). day =
--   `ts::date` (the correction's row timestamp, not the partition). The lexical %-of-user
--   -messages check is the volume-sanity gate: if lexical > 5% of a runtime's
--   user messages the marker list is too loose.
-- CAVEATS: candidates are PRE-adjudication -- volume is not precision. tool_reject +
--   interrupt_redirect are Claude Code only (opencode records no user-verdict/interrupt);
--   opencode contributes lexical + rewrite only. Counts move as the lake grows.
-- Run: just sql -f mining/queries/corrections_candidates.sql
CREATE TEMP TABLE _cc AS SELECT * FROM correction_candidates;

-- (1) per detector x runtime
SELECT runtime, detector, any_value(detector_version) AS detector_version, count(*) AS candidates
FROM _cc GROUP BY ALL ORDER BY runtime, detector;

-- (2) lexical volume-sanity gate: lexical hits as a share of each runtime's user messages
SELECT
  um.runtime,
  um.user_msgs,
  coalesce(lx.lexical_hits, 0)                                     AS lexical_hits,
  round(100.0 * coalesce(lx.lexical_hits, 0) / nullif(um.user_msgs, 0), 3) AS lexical_pct,
  CASE WHEN coalesce(lx.lexical_hits, 0) > 0.05 * um.user_msgs THEN 'OVER 5% -- TIGHTEN MARKERS'
       ELSE 'ok' END                                              AS gate
FROM (SELECT runtime, count(*) AS user_msgs FROM messages WHERE role = 'user' GROUP BY 1) um
LEFT JOIN (SELECT runtime, count(*) AS lexical_hits FROM _cc WHERE detector = 'lexical' GROUP BY 1) lx
  USING (runtime)
ORDER BY um.runtime;

-- (3) per detector x day (trend; the longitudinal clock)
SELECT ts::date AS day, detector, count(*) AS candidates
FROM _cc GROUP BY ALL ORDER BY day DESC, detector;

-- (4) per estate x harness x detector (where corrections concentrate)
SELECT estate, harness, detector, count(*) AS candidates, count(DISTINCT session_id) AS sessions
FROM _cc GROUP BY ALL ORDER BY candidates DESC;

-- (5) lexical marker mix + rewrite overlap spread (per-marker precision is measured at
--     adjudication; this shows where the volume sits)
SELECT runtime, features ->> 'marker' AS lexical_marker, count(*) AS candidates
FROM _cc WHERE detector = 'lexical' GROUP BY ALL ORDER BY runtime, candidates DESC;
