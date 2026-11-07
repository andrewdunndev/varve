-- QUESTION: Which correction candidates should be labelled for precision? A stratified
--   sample with everything needed to label each one (true or false positive, plus the
--   context confound) without dereferencing every locus by hand. Mining does not feed
--   analysis until precision is measured on labels the operator produces from this
--   sample. No precision number is computed here.
-- METRIC: up to 50 candidates per detector, stratified by detector. Sampling is
--   deterministic (ORDER BY md5(candidate_id)), so the same sample reproduces run to run
--   and adjudications stay joinable.
-- OUTPUT per row: candidate_id (write it into the adjudication line), detector, loci in
--   the non-identifying `lake:` form, model_id (the non-stationarity covariate),
--   estate/harness/campaign, features, a truncated excerpt, and a ready-to-fill JSONL
--   skeleton.
--
-- EXCERPT: the corrective message, the operator's own words (for tool_reject, the
--   rejection reason), capped at 240 chars and whitespace-collapsed. An adjudicator
--   labelling 50 loci per detector needs the correction at a glance, and a role-level
--   verdict is judgeable from the operator's words. The corrected draft stays a locus
--   (draft_locus) to dereference live when judging context, so little model or work
--   content reaches the output.
--   Confidentiality (ADR-0004): the excerpt is computed at query time from lake content
--   and printed to the operator's terminal. This file holds no transcript content. Never
--   redirect the output into the repo or off ~/.local/share/varve.
-- Run: just sql -f mining/queries/adjudication_sample.sql
--   (or one detector: just sql -c "SET VARIABLE det='lexical'" -f mining/queries/adjudication_sample.sql)

CREATE TEMP TABLE _sample AS
SELECT c.*,
  row_number() OVER (PARTITION BY c.detector ORDER BY md5(c.candidate_id)) AS _rn
FROM correction_candidates c
WHERE coalesce(try_cast(getvariable('det') AS VARCHAR), c.detector) = c.detector
QUALIFY _rn <= 50;

SELECT
  s.detector,
  s.candidate_id,
  s.model_id,
  s.estate, s.harness, s.campaign,
  s.ts,
  s.features,
  'lake:' || s.session_id || '/' || s.message_uuid                    AS locus,          -- corrective msg
  'lake:' || s.session_id || '/' || coalesce(s.prior_assistant_uuid, '') AS draft_locus, -- corrected draft
  -- truncated, whitespace-collapsed excerpt of the corrective message (LAKE-LOCAL ONLY).
  -- A locus outside operator_context (an opencode denied call) shows that message's own text.
  left(regexp_replace(coalesce(oc.speech, trim(m.text)), '[[:space:]]+', ' ', 'g'), 240) AS excerpt,
  -- copy-paste, fill verdict + context_judgment (+ optional note = role-level gloss only)
  '{"candidate_id":"' || s.candidate_id
    || '","verdict":"","context_judgment":"","note":""}'               AS adjudication_line
FROM _sample s
JOIN messages m
  ON m.runtime = s.runtime AND m.session_id = s.session_id AND m.message_id = s.message_uuid
LEFT JOIN (SELECT runtime, session_id, message_id, min(speech) AS speech
           FROM operator_context GROUP BY ALL) oc
  ON oc.runtime = s.runtime AND oc.session_id = s.session_id AND oc.message_id = s.message_uuid
ORDER BY s.detector, s.candidate_id;
