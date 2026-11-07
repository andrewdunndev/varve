-- QUESTION: How many corrections did mining miss? Of the operator messages no detector
--   flagged, how many are corrections: the recall floor. Mining is tuned for precision
--   over recall, so this measures the blind spot once instead of assuming it away:
--   adjudicate a sample of unflagged operator messages and report detected against
--   undetected. The sample is also the selection-bias denominator arm: every event
--   carries `selection` {organic|sampled}; mined promotions are organic, this population
--   is sampled.
-- METRIC: missed-correction rate = (rows from this sample labelled verdict=true_positive)
--   / (rows sampled here). A recall floor, not the true recall: only this sample is
--   adjudicated, not the whole flagged=false population. Read alongside per-detector
--   precision to bound overall recall from both sides.
-- SAMPLE: 50 rows from `operator_messages` WHERE flagged=false, deterministic
--   (ORDER BY md5(message_uuid)) so the sample reproduces run to run. flagged means "also
--   a correction_candidates locus", so no row here overlaps correction_candidates.
-- OUTPUT per row: the same shape as adjudication_sample.sql: loci (`lake:` form),
--   attribution (estate/harness/campaign), a truncated excerpt of the message, and a
--   ready-to-fill JSONL skeleton. The skeleton keys on `message_uuid` (these messages were
--   never flagged, so there is no candidate_id) and fixes `"selection":"sampled"`, so
--   recall-floor labels stay distinguishable from precision-sample labels once both land
--   in the same adjudication ledger.
--
-- EXCERPT: as in adjudication_sample.sql. A 240-char, whitespace-collapsed rendering of
--   the operator message, computed at query time from lake content and printed to the
--   operator's terminal. Confidentiality (ADR-0004): this file holds no transcript
--   content. Never redirect the output into the repo or off ~/.local/share/varve.
-- Run: just sql -f mining/queries/recall_floor_sample.sql

CREATE TEMP TABLE _floor_sample AS
SELECT om.*
FROM operator_messages om
WHERE NOT om.flagged
ORDER BY md5(om.message_uuid)
LIMIT 50;

SELECT
  s.runtime,
  s.estate, s.harness, s.campaign,
  s.ts,
  'lake:' || s.session_id || '/' || s.message_uuid                    AS locus,
  -- truncated, whitespace-collapsed excerpt of the operator message (LAKE-LOCAL ONLY).
  left(regexp_replace(m.speech, '[[:space:]]+', ' ', 'g'), 240)       AS excerpt,
  -- copy-paste, fill verdict + context_judgment (+ optional note = role-level gloss only)
  '{"message_uuid":"' || s.message_uuid
    || '","selection":"sampled","verdict":"","context_judgment":"","note":""}' AS adjudication_line
FROM _floor_sample s
JOIN (SELECT runtime, session_id, message_id, min(speech) AS speech
      FROM operator_context GROUP BY ALL) m
  ON m.runtime = s.runtime AND m.session_id = s.session_id AND m.message_id = s.message_uuid
ORDER BY md5(s.message_uuid);
