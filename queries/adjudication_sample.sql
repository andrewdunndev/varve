-- QUESTION: Give the operator a stratified sample of correction candidates to adjudicate,
--   with everything needed to label each one (true/false positive + the context confound)
--   without hand-dereferencing every locus. This is the deliverable for G-precision
--   (RFC-0002): mining does NOT feed analysis until precision is measured on labels the
--   operator produces from THIS sample. It fabricates no precision numbers.
-- METRIC: up to 50 candidates per detector ("50 or all, whichever is smaller", RFC-0002),
--   stratified by detector. Sampling is deterministic (ORDER BY md5(candidate_id)) so the
--   same sample reproduces run to run and adjudications stay joinable.
-- OUTPUT per row: candidate_id (write it into the adjudication line), detector loci
--   (non-identifying `lake:` form -- I5), model_id (the non-stationarity covariate),
--   estate/harness/campaign, features, a truncated EXCERPT, and a ready-to-fill JSONL
--   skeleton.
--
-- EXCERPT CHOICE (builder decision; RFC-0002 open question "excerpt vs dereference").
--   This query emits a truncated content excerpt of the CORRECTIVE message (the operator's
--   own utterance; for tool_reject, the operator's rejection reason). Rationale: an
--   adjudicator labelling 50+ loci per detector needs the correction at a glance; live-
--   dereferencing every locus is the ergonomic tax the review loop cannot afford, and a
--   role-level true/false-positive verdict is judgeable from the operator's own words.
--   Confidentiality (ADR-0004): the excerpt is LAKE-LOCAL ONLY -- it is computed at query
--   time from lake content and printed to the operator's terminal; it is NEVER written to
--   a repo-committed file (this .sql contains zero transcript content) and NEVER exported.
--   Do NOT redirect this query's output into the repo or off ~/.local/share/varve. Only
--   the corrective message is excerpted (operator speech); the corrected DRAFT is left as
--   a locus (draft_locus) to dereference live when judging context, minimising model/work
--   content in the output. Excerpt is capped at 240 chars, whitespace-collapsed.
-- W7. Run: just sql -f queries/adjudication_sample.sql
--   (or one detector: just sql -c "SET VARIABLE det='lexical'" -f queries/adjudication_sample.sql)

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
    '[[:space:]]+', ' ', 'g'), 240)                                    AS excerpt,
  -- copy-paste, fill verdict + context_judgment (+ optional note = role-level gloss only)
  '{"candidate_id":"' || s.candidate_id
    || '","verdict":"","context_judgment":"","note":""}'               AS adjudication_line
FROM _sample s
JOIN messages m
  ON m.runtime = s.runtime AND m.session_id = s.session_id AND m.message_id = s.message_uuid
ORDER BY s.detector, s.candidate_id;
