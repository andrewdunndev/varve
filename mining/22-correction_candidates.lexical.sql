-- Detector lexical: an operator message that opens with a correction marker
-- (kind marker in patterns), after an optional leading interjection, directly
-- following an assistant draft. The hit's name lands in features, so precision
-- is measurable per marker.
-- Candidate id: md5 of detector, runtime, session and message, so adjudications
-- keep their keys. Version: the hash of this file; a patterns change does not move it.

SET VARIABLE interjection = coalesce(
  '^(' || (SELECT string_agg(pattern, '|') FROM patterns WHERE kind = 'interjection') || ')[^a-z0-9]+',
  '$^');

CREATE TEMP TABLE _d AS
SELECT ctx.runtime, ctx.session_id, ctx.message_id AS message_uuid, ctx.prior_asst_uuid, ctx.ts,
       'lexical' AS detector,
       json_object('marker', mk.name) AS features,
       ctx.model_id
FROM operator_context ctx
JOIN (SELECT name, pattern FROM patterns WHERE kind = 'marker') mk
  ON regexp_matches(regexp_replace(lower(trim(ctx.body)), getvariable('interjection'), ''), mk.pattern)
WHERE ctx.is_operator AND ctx.prior_asst_uuid IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY ctx.runtime, ctx.session_id, ctx.message_id
                           ORDER BY mk.name) = 1;

CREATE TEMP TABLE mine_out AS
SELECT
  'cand-' || md5(d.detector || '|' || d.runtime || '|' || d.session_id || '|' || coalesce(d.message_uuid, '')) AS candidate_id,
  d.session_id, d.message_uuid, d.prior_asst_uuid AS prior_assistant_uuid, d.ts,
  d.detector, (SELECT md5(content) FROM read_text(getvariable('mine_file'))) AS detector_version,
  d.features, d.model_id, s.estate, s.harness, s.campaign, s.date AS date, d.runtime
FROM _d d
ANTI JOIN (SELECT runtime, session_id, message_id FROM operator_context WHERE is_copy) cp
  ON cp.runtime = d.runtime AND cp.session_id = d.session_id AND cp.message_id = d.message_uuid
JOIN sessions s ON s.runtime = d.runtime AND s.session_id = d.session_id
QUALIFY row_number() OVER (PARTITION BY candidate_id
                           ORDER BY d.features::varchar, d.prior_asst_uuid, d.ts, d.model_id) = 1;
