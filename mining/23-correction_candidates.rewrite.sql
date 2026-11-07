-- Detector rewrite: an operator message whose token set overlaps the preceding
-- assistant draft but is not identical, the operator restating the model.
-- Jaccard on lowercased word unigrams, banded to [0.5, 0.9). A score near 1.0 is
-- an echo, the operator pasting model text forward, which is a different signal.
-- Candidate id: md5 of detector, runtime, session and message, so adjudications
-- keep their keys. Version: the hash of this file.

CREATE OR REPLACE TEMP MACRO _tok(s) AS
  list_distinct(list_filter(regexp_split_to_array(lower(coalesce(s, '')), '[^a-z0-9]+'),
                            lambda x: length(x) > 0));

CREATE TEMP TABLE _d AS
SELECT s.runtime, s.session_id, s.message_uuid, s.prior_asst_uuid, s.ts, s.detector,
       json_object('jaccard', round(s.jaccard, 4), 'body_tokens', s.body_tokens,
                   'prior_tokens', s.prior_tokens) AS features,
       s.model_id
FROM (
  SELECT
    ctx.runtime, ctx.session_id, ctx.message_id AS message_uuid, ctx.prior_asst_uuid, ctx.ts,
    'rewrite' AS detector,
    len(list_intersect(_tok(ctx.body), _tok(pm.text)))::double
      / nullif(len(list_distinct(list_concat(_tok(ctx.body), _tok(pm.text)))), 0) AS jaccard,
    len(_tok(ctx.body)) AS body_tokens, len(_tok(pm.text)) AS prior_tokens,
    ctx.model_id
  FROM operator_context ctx
  JOIN (SELECT runtime, session_id, message_id, text FROM messages
        WHERE role = 'assistant' AND text IS NOT NULL
        QUALIFY row_number() OVER (PARTITION BY runtime, session_id, message_id ORDER BY text) = 1) pm
    ON pm.runtime = ctx.runtime AND pm.session_id = ctx.session_id AND pm.message_id = ctx.prior_asst_uuid
  WHERE ctx.is_operator
    AND length(trim(pm.text)) >= 20 AND length(trim(ctx.body)) >= 20
    AND lower(trim(ctx.body)) <> lower(trim(pm.text))
) s
WHERE jaccard >= 0.5 AND jaccard < 0.9;

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
