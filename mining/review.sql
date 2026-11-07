-- varve adjudication review renderer. Builds the review document
-- from the lake + the model-suggested worksheet, so the operator can adjudicate correction
-- candidates with the full prior draft and full corrective message in front of them
-- (context_judgment is largely un-inferable from a 240-char excerpt).
--
-- Invoked by the justfile `review` recipe (through bin/duck), which then COPYs
-- stg_review_document to <data_home>/review_round1.md. Same idiom as mining/corrections.sql:
-- lake-local read views over the Parquet, a stg_ table the recipe writes out (COPY targets
-- are literals -- the recipe injects the output path).
--
-- Variables (set by the recipe):
--   lake          : <data_home>/lake (read core Parquet + the mining tables)
--   adjudications : path to the JSONL adjudication ledger (operator data, outside the repo;
--                   the recipe guarantees the path EXISTS -- empty temp file when absent).
--                   Used ONLY to SKIP already-adjudicated loci so re-render is idempotent as
--                   the ledger grows.
--   worksheet     : path to the model-suggested worksheet JSONL (advisory; read with
--                   read_json_auto). The recipe guarantees the path EXISTS and is non-empty
--                   (priming a non-matching sentinel row when absent) so the advisory LEFT
--                   JOIN degrades gracefully to "no advisory" -- worksheet absence is non-fatal.
--
-- CONFIDENTIALITY (ADR-0004): this .sql holds ZERO transcript
-- content. Draft/message text is dereferenced from the LOCAL lake at run time and written
-- ONLY under the data home (the review_round1.md the recipe COPYs). Loci are the
-- non-identifying `lake:` form. Nothing here is printed to a terminal or emitted off the
-- data home.
-- =====================================================================================

-- Lake-local read views (the same read_parquet shape bin/duck generates; local to this session).
CREATE OR REPLACE VIEW _rv_messages AS
  SELECT * FROM read_parquet(getvariable('lake') || '/messages/**/*.parquet',
    hive_partitioning = true, union_by_name = true);
CREATE OR REPLACE VIEW _rv_candidates AS
  SELECT * FROM read_parquet(getvariable('lake') || '/correction_candidates/**/*.parquet',
    hive_partitioning = true, union_by_name = true);
CREATE OR REPLACE VIEW _rv_opmsgs AS
  SELECT * FROM read_parquet(getvariable('lake') || '/operator_messages/**/*.parquet',
    hive_partitioning = true, union_by_name = true);

-- Ledger: candidate_ids and message_uuids already adjudicated (any verdict). Read exactly
-- as mining/corrections.sql reads it. Drives the idempotent SKIP -- an adjudicated locus
-- drops out of the next render.
CREATE OR REPLACE TABLE _rv_ledger AS
SELECT j ->> 'candidate_id' AS candidate_id, j ->> 'message_uuid' AS message_uuid
FROM read_json_objects(getvariable('adjudications'),
       format = 'newline_delimited', ignore_errors = true) t(j);
CREATE OR REPLACE TABLE _rv_ledger_cands AS
  SELECT DISTINCT candidate_id FROM _rv_ledger WHERE candidate_id IS NOT NULL;
CREATE OR REPLACE TABLE _rv_ledger_msgs AS
  SELECT DISTINCT message_uuid FROM _rv_ledger WHERE message_uuid IS NOT NULL;

-- Advisory worksheet (model-suggested labels + role-level rationale). read_json_auto per the
-- brief; the recipe guarantees a readable, non-empty file so schema inference always succeeds.
CREATE OR REPLACE TABLE _rv_worksheet AS
  SELECT * FROM read_json_auto(getvariable('worksheet'));

-- Tool results by carrier row, for a rejected tool call whose corrective "message" is the
-- carrier of the result.
CREATE OR REPLACE VIEW _rv_tool_calls AS
  SELECT * FROM read_parquet(getvariable('lake') || '/tool_calls/**/*.parquet',
    hive_partitioning = true, union_by_name = true);
CREATE OR REPLACE TABLE _rv_carriers AS
  SELECT runtime, session_id, result_message_id AS message_id,
         string_agg(result_text, chr(10)) AS result_txt
  FROM _rv_tool_calls WHERE runtime = 'claude-code' AND result_message_id IS NOT NULL
  GROUP BY runtime, session_id, result_message_id;

-- Full operator/corrective text, not truncated -- the whole point of the review doc.
-- The row's own text, else the text of the tool result it carries with the harness
-- "the user said:" prefix stripped. Interrupt marker stripped. The adapters join text
-- blocks with a literal backslash-n; shown here as a line break.
CREATE OR REPLACE MACRO _rv_usertext(txt, carried) AS
  trim(regexp_replace(
    replace(coalesce(nullif(txt, ''),
                     regexp_replace(carried, '^.*?the user said:\s*', ''),
                     txt), '\n', chr(10)),
    '^\[Request interrupted by user[^\]]*\]', ''));

-- Full assistant-draft text. NULL when there is no prior draft (handled gracefully
-- downstream -- D1 tool-decision loci structurally reference a tool result, not a text draft).
CREATE OR REPLACE MACRO _rv_assttext(txt) AS replace(txt, '\n', chr(10));

-- -------------------------------------------------------------------------------------
-- PART 1 -- flagged candidates. One row per candidate NOT yet in the ledger, enriched with
-- the dereferenced full draft + full corrective message and the model's advisory suggestion.
CREATE OR REPLACE TABLE _rv_cand AS
SELECT
  c.candidate_id, c.detector, c.runtime, c.session_id, c.message_uuid, c.prior_assistant_uuid,
  c.model_id, c.estate, c.harness, c.campaign, c.features,
  _rv_usertext(cm.text, cc.result_txt)                     AS corrective_txt,
  _rv_assttext(am.text)                                    AS draft_txt,
  w.suggested_verdict, w.suggested_context_judgment, w.rationale, w.suggested_by, w.suggested_at
FROM _rv_candidates c
LEFT JOIN _rv_messages cm
  ON cm.runtime = c.runtime AND cm.session_id = c.session_id AND cm.message_id = c.message_uuid
LEFT JOIN _rv_messages am
  ON am.runtime = c.runtime AND am.session_id = c.session_id AND am.message_id = c.prior_assistant_uuid
LEFT JOIN _rv_carriers cc
  ON cc.runtime = c.runtime AND cc.session_id = c.session_id AND cc.message_id = c.message_uuid
LEFT JOIN _rv_worksheet w
  ON w.candidate_id = c.candidate_id
WHERE c.candidate_id NOT IN (SELECT candidate_id FROM _rv_ledger_cands);

-- -------------------------------------------------------------------------------------
-- PART 2 -- recall-floor sample. The DETERMINISTIC top-50 unflagged operator messages
-- (ORDER BY md5(message_uuid), matching mining/queries/recall_floor_sample.sql so the floor
-- denominator is a stable set), with already-adjudicated loci dropped from the render (the
-- sample IDENTITY stays those 50; we do not backfill, which would shift the denominator).
CREATE OR REPLACE TABLE _rv_floor AS
WITH f50 AS (
  SELECT * FROM _rv_opmsgs WHERE NOT flagged
  ORDER BY md5(message_uuid) LIMIT 50
)
SELECT
  f.runtime, f.session_id, f.message_uuid, f.estate, f.harness, f.campaign,
  _rv_usertext(m.text, NULL)                            AS operator_txt
FROM f50 f
LEFT JOIN _rv_messages m
  ON m.runtime = f.runtime AND m.session_id = f.session_id AND m.message_id = f.message_uuid
WHERE f.message_uuid NOT IN (SELECT message_uuid FROM _rv_ledger_msgs);

-- =====================================================================================
-- Assemble the document: one row per block, ordered by (part, ord2, ord3). The recipe COPYs
-- `md` out with QUOTE '' so embedded newlines/commas survive verbatim.
-- =====================================================================================
CREATE OR REPLACE TABLE stg_review_document AS
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
