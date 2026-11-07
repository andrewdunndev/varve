-- Detector interrupt_redirect (claude-code): an interrupt followed by a redirect.
--   inline       the interrupt message itself carries redirect text.
--   next_message a bare interrupt; the redirect is the next operator message,
--                guarded to the same draft so no new assistant turn intervened.
--                The locus is the redirect.
-- Candidate id: md5 of detector, runtime, session and message, so adjudications
-- keep their keys. Version: the hash of this file.

CREATE TEMP TABLE _interrupts AS
SELECT ctx.message_id AS interrupt_uuid, ctx.session_id, ctx.runtime, ctx.ts,
       ctx.prior_asst_uuid, ctx.model_id,
       ((NOT ctx.is_noise) AND length(trim(ctx.body)) > 20) AS has_inline_redirect
FROM operator_context ctx
WHERE ctx.runtime = 'claude-code' AND ctx.interrupted;

CREATE TEMP TABLE _op_operator AS SELECT * FROM operator_context WHERE is_operator;

CREATE TEMP TABLE _d AS
SELECT i.runtime, i.session_id, i.interrupt_uuid AS message_uuid, i.prior_asst_uuid, i.ts,
       'interrupt_redirect' AS detector,
       json_object('mode', 'inline') AS features,
       i.model_id
FROM _interrupts i
WHERE i.has_inline_redirect
UNION ALL BY NAME
SELECT r.runtime, r.session_id, r.message_id AS message_uuid, r.prior_asst_uuid, r.ts,
       'interrupt_redirect' AS detector,
       json_object('mode', 'next_message', 'interrupt_uuid', i.interrupt_uuid) AS features,
       r.model_id
FROM _interrupts i
JOIN LATERAL (
  SELECT o2.* FROM _op_operator o2
  WHERE o2.runtime = i.runtime AND o2.session_id = i.session_id AND o2.ts > i.ts
  ORDER BY o2.ts, o2.message_id LIMIT 1
) r ON true
WHERE NOT i.has_inline_redirect
  AND r.prior_asst_uuid IS NOT DISTINCT FROM i.prior_asst_uuid
-- Repeated interrupts fan into one redirect; keep the nearest interrupt.
QUALIFY row_number() OVER (PARTITION BY r.runtime, r.session_id, r.message_id
                           ORDER BY i.ts DESC, i.interrupt_uuid DESC) = 1;

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
