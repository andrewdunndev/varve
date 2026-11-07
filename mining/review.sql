-- Renders the adjudication review document from the mined tables and the
-- advisory worksheet, so the operator judges each correction candidate with the
-- full prior draft and the full corrective message in front of them. A 240-char
-- excerpt rarely settles context_judgment.
--
-- `just review` runs this through bin/duck and writes review_document out as
-- markdown. Reads the generated views: messages, correction_candidates,
-- operator_messages, operator_context, adjudications and adjudication_worksheet.
--   adjudications           ledger JSONL in the data home. Used only to skip loci
--                           already adjudicated, so a re-render shrinks as the
--                           ledger grows.
--   adjudication_worksheet  advisory JSONL, one object per line: candidate_id,
--                           suggested_verdict, suggested_context_judgment, rationale,
--                           suggested_by, suggested_at. Absent means no advisory.
--
-- Confidentiality (ADR-0004): this file holds no transcript content. Draft and
-- message text is read from the local lake at run time and written only under the
-- data home. Loci are the non-identifying `lake:` form. Nothing is printed to a
-- terminal.

CREATE VIEW IF NOT EXISTS adjudications AS SELECT NULL::JSON AS j WHERE false;
CREATE VIEW IF NOT EXISTS adjudication_worksheet AS SELECT NULL::JSON AS j WHERE false;

CREATE TEMP TABLE _rv_ledger AS
SELECT j ->> 'candidate_id' AS candidate_id, j ->> 'message_uuid' AS message_uuid
FROM adjudications;
CREATE TEMP TABLE _rv_ledger_cands AS
  SELECT DISTINCT candidate_id FROM _rv_ledger WHERE candidate_id IS NOT NULL;
CREATE TEMP TABLE _rv_ledger_msgs AS
  SELECT DISTINCT message_uuid FROM _rv_ledger WHERE message_uuid IS NOT NULL;

CREATE TEMP TABLE _rv_worksheet AS
SELECT j ->> 'candidate_id'                AS candidate_id,
       j ->> 'suggested_verdict'           AS suggested_verdict,
       j ->> 'suggested_context_judgment'  AS suggested_context_judgment,
       j ->> 'rationale'                   AS rationale,
       j ->> 'suggested_by'                AS suggested_by,
       j ->> 'suggested_at'                AS suggested_at
FROM adjudication_worksheet;

-- One speech per message. The adapters join text blocks with a literal backslash-n;
-- _rv_text shows it as a line break. A locus outside operator_context (an opencode
-- denied call points at the assistant message) falls back to that message's own text.
CREATE TEMP TABLE _rv_speech AS
SELECT runtime, session_id, message_id, min(speech) AS speech
FROM operator_context GROUP BY ALL;

CREATE OR REPLACE TEMP MACRO _rv_text(speech, txt) AS
  trim(replace(coalesce(speech, txt), '\n', chr(10)));

-- Full assistant-draft text. NULL when there is no prior draft (handled gracefully
-- downstream -- tool-decision loci reference a tool result, not a text draft).
CREATE OR REPLACE TEMP MACRO _rv_assttext(txt) AS replace(txt, '\n', chr(10));

-- -------------------------------------------------------------------------------------
-- PART 1 -- flagged candidates. One row per candidate NOT yet in the ledger, enriched with
-- the dereferenced full draft + full corrective message and the model's advisory suggestion.
CREATE TEMP TABLE _rv_cand AS
SELECT
  c.candidate_id, c.detector, c.runtime, c.session_id, c.message_uuid, c.prior_assistant_uuid,
  c.model_id, c.estate, c.harness, c.campaign, c.features,
  _rv_text(sp.speech, cm.text)                             AS corrective_txt,
  _rv_assttext(am.text)                                    AS draft_txt,
  w.suggested_verdict, w.suggested_context_judgment, w.rationale, w.suggested_by, w.suggested_at
FROM correction_candidates c
LEFT JOIN messages cm
  ON cm.runtime = c.runtime AND cm.session_id = c.session_id AND cm.message_id = c.message_uuid
LEFT JOIN messages am
  ON am.runtime = c.runtime AND am.session_id = c.session_id AND am.message_id = c.prior_assistant_uuid
LEFT JOIN _rv_speech sp
  ON sp.runtime = c.runtime AND sp.session_id = c.session_id AND sp.message_id = c.message_uuid
LEFT JOIN _rv_worksheet w
  ON w.candidate_id = c.candidate_id
WHERE c.candidate_id NOT IN (SELECT candidate_id FROM _rv_ledger_cands);

-- -------------------------------------------------------------------------------------
-- PART 2 -- recall-floor sample. The DETERMINISTIC top-50 unflagged operator messages
-- (ORDER BY md5(message_uuid), matching mining/queries/recall_floor_sample.sql so the floor
-- denominator is a stable set), with already-adjudicated loci dropped from the render (the
-- sample IDENTITY stays those 50; we do not refill, which would shift the denominator).
CREATE TEMP TABLE _rv_floor AS
WITH f50 AS (
  SELECT * FROM operator_messages WHERE NOT flagged
  ORDER BY md5(message_uuid) LIMIT 50
)
SELECT
  f.runtime, f.session_id, f.message_uuid, f.estate, f.harness, f.campaign,
  _rv_text(sp.speech, NULL)                             AS operator_txt
FROM f50 f
LEFT JOIN _rv_speech sp
  ON sp.runtime = f.runtime AND sp.session_id = f.session_id AND sp.message_id = f.message_uuid
WHERE f.message_uuid NOT IN (SELECT message_uuid FROM _rv_ledger_msgs);


-- =====================================================================================
-- Assemble the document: one row per block, ordered by (part, ord2, ord3). The recipe COPYs
-- `md` out with QUOTE '' so embedded newlines/commas survive verbatim.
-- =====================================================================================
CREATE OR REPLACE TABLE review_document AS
-- part 0: document header + Part-1 banner (counts computed from the assembled tables)
SELECT 0 AS part, '' AS ord2, '' AS ord3,
  '# varve -- correction adjudication review (round 1)' || chr(10) || chr(10)
  || '_Generated ' || strftime(now(), '%Y-%m-%d %H:%M:%S') || '._ '
  || 'Candidates to adjudicate: ' || (SELECT count(*) FROM _rv_cand)::varchar
  || ' -- recall-floor sample: ' || (SELECT count(*) FROM _rv_floor)::varchar
  || ' (already-adjudicated loci are skipped).' || chr(10) || chr(10)
  || 'For each candidate below: read the FULL prior draft and FULL corrective message, then '
  || 'copy the adjudication line into your adjudications ledger and fill `verdict` '
  || '(true_positive | false_positive | unclear) and `context_judgment` '
  || '(had_context | lacked_context | ambiguous). The ADVISORY line is the model''s '
  || 'suggestion, NOT a verdict.' || chr(10) || chr(10)
  || '## Part 1 -- flagged candidates' AS md
UNION ALL BY NAME
-- part 1: candidate sections
SELECT 1 AS part, cr.detector AS ord2, cr.candidate_id AS ord3,
  '### ' || cr.detector || ' -- ' || cr.candidate_id || chr(10) || chr(10)
  || '- locus (corrective message): `lake:' || cr.session_id || '/' || cr.message_uuid || '`' || chr(10)
  || '- locus (prior draft): `lake:' || cr.session_id || '/' || coalesce(cr.prior_assistant_uuid, '(none)') || '`' || chr(10)
  || '- model_id: ' || coalesce(cr.model_id, '(unknown)') || chr(10)
  || '- attribution: ' || coalesce(cr.estate, '') || ' / ' || coalesce(cr.harness, '') || ' / ' || coalesce(cr.campaign, '') || chr(10)
  || '- features: `' || coalesce(cr.features::varchar, '') || '`' || chr(10) || chr(10)
  || CASE WHEN cr.suggested_verdict IS NULL
       THEN '**ADVISORY:** none (candidate not in the worksheet).'
       ELSE '**ADVISORY (model suggestion, NOT a verdict):** verdict=`' || coalesce(cr.suggested_verdict, '')
            || '` | context_judgment=`' || coalesce(cr.suggested_context_judgment, '')
            || '` | by=' || coalesce(cr.suggested_by, '') || ' @ ' || coalesce(cr.suggested_at, '') || chr(10)
            || '> rationale: ' || coalesce(cr.rationale, '')
     END || chr(10) || chr(10)
  || '--- PRIOR ASSISTANT DRAFT (full) ---' || chr(10)
  || coalesce(cr.draft_txt,
       '(no prior assistant draft at this locus. D1 tool-decision rejections reference a tool result, not a text draft.)')
     || chr(10) || chr(10)
  || '--- CORRECTIVE OPERATOR MESSAGE (full) ---' || chr(10)
  || coalesce(cr.corrective_txt, '(corrective message text unavailable at this locus.)') || chr(10) || chr(10)
  || 'Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):' || chr(10) || chr(10)
  || '    {"candidate_id":"' || cr.candidate_id || '","verdict":"","context_judgment":"","note":""}' || chr(10) || chr(10)
  || '---' AS md
FROM _rv_cand cr
UNION ALL BY NAME
-- part 2: recall-floor banner
SELECT 2 AS part, '' AS ord2, '' AS ord3,
  '## Part 2 -- recall-floor sample (unflagged operator messages)' || chr(10) || chr(10)
  || 'Adjudicate these to measure what mining MISSED (the recall floor). These operator '
  || 'messages were flagged by NO detector. Keyed on `message_uuid`; the skeleton fixes '
  || '`"selection":"sampled"` so recall-floor labels stay distinguishable from precision-sample '
  || 'labels in the ledger.' AS md
UNION ALL BY NAME
-- part 3: recall-floor sections (deterministic md5 order, matching recall_floor_sample.sql)
SELECT 3 AS part, '' AS ord2, md5(fr.message_uuid) AS ord3,
  '### recall-floor -- ' || fr.message_uuid || chr(10) || chr(10)
  || '- locus: `lake:' || fr.session_id || '/' || fr.message_uuid || '`' || chr(10)
  || '- attribution: ' || coalesce(fr.estate, '') || ' / ' || coalesce(fr.harness, '') || ' / ' || coalesce(fr.campaign, '') || chr(10) || chr(10)
  || '--- OPERATOR MESSAGE (full) ---' || chr(10)
  || coalesce(fr.operator_txt, '(operator message text unavailable at this locus.)') || chr(10) || chr(10)
  || 'Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):' || chr(10) || chr(10)
  || '    {"message_uuid":"' || fr.message_uuid || '","selection":"sampled","verdict":"","context_judgment":"","note":""}' || chr(10) || chr(10)
  || '---' AS md
FROM _rv_floor fr;
