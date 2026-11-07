-- QUESTION: Of operator messages mining did NOT flag, how many are correction misses --
--   the recall floor. Mining is tuned precision-over-recall, so
--   this measures the blind spot once rather than assuming it away: adjudicate a random
--   sample of unflagged operator messages and report detected/undetected. This sample is
--   also the selection-bias denominator arm -- every event carries `selection`
--   {organic|sampled}; mined promotions are organic, this population is sampled.
-- METRIC: adjudicated missed-correction rate = (rows from THIS sample labelled
--   verdict=true_positive) / (rows sampled here) -- a recall FLOOR, not the true recall
--   (only this sample is adjudicated, not the full flagged=false population). Read
--   alongside per-detector precision to bound overall recall from both sides.
-- SAMPLE: 50 rows from `operator_messages` WHERE flagged=false ("random sample of
--   user-after-assistant messages NOT flagged by any detector"), deterministic
--   (ORDER BY md5(message_uuid)) so the sample reproduces run to run. By construction
--   (flagged is defined as "also a correction_candidates locus"), zero rows here overlap
--   correction_candidates.
-- OUTPUT per row: the same shape as adjudication_sample.sql -- loci (`lake:` form),
--   attribution (estate/harness/campaign), a truncated EXCERPT of the message, and a
--   ready-to-fill JSONL skeleton. The skeleton keys on `message_uuid` (there is no
--   candidate_id -- these messages were never flagged) and fixes `"selection":"sampled"`
--   so recall-floor labels are distinguishable from precision-sample labels once both
--   land in the same adjudication ledger.
--
-- EXCERPT + CONFIDENTIALITY (as in adjudication_sample.sql;
--   ADR-0004): the excerpt is a truncated (240-char, whitespace-collapsed) rendering of
--   the operator message, computed at query time from lake content and printed to the
--   operator's terminal. It is LAKE-LOCAL ONLY -- NEVER written to a repo-committed file
--   (this .sql contains zero transcript content) and NEVER exported. Do not redirect this
--   query's output into the repo or off ~/.local/share/varve.
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
  left(regexp_replace(
    trim(regexp_replace(
      CASE
        WHEN s.runtime = 'claude-code' AND json_type(m.content) = 'VARCHAR'
          THEN json_extract_string(m.content, '$')
        WHEN s.runtime = 'claude-code' AND json_type(m.content) = 'ARRAY'
          THEN coalesce(
                 nullif(array_to_string(json_extract(m.content, '$[*].text')::varchar[], ' '), ''),
                 regexp_replace(array_to_string(json_extract(m.content, '$[*].content')::varchar[], ' '),
                                '^.*?the user said:\s*', ''))
        ELSE m.content
      END, '^\[Request interrupted by user[^\]]*\]', '')),
    '[[:space:]]+', ' ', 'g'), 240)                                   AS excerpt,
  -- copy-paste, fill verdict + context_judgment (+ optional note = role-level gloss only)
  '{"message_uuid":"' || s.message_uuid
    || '","selection":"sampled","verdict":"","context_judgment":"","note":""}' AS adjudication_line
FROM _floor_sample s
JOIN messages m
  ON m.runtime = s.runtime AND m.session_id = s.session_id AND m.message_id = s.message_uuid
ORDER BY md5(s.message_uuid);
