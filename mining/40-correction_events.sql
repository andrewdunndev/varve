-- Saves correction_events: candidates the operator confirmed. The adjudication
-- ledger (adjudications.jsonl in the data home) is one JSON object per line:
--   candidate_id      required; joins a candidate
--   verdict           required; true_positive, false_positive or unclear
--   context_judgment  had_context, lacked_context or ambiguous
--   note              role-level gloss only, never verbatim text
--   adjudicated_at    ISO timestamp
-- Only true_positive rows promote. With no ledger there are no events. Category
-- is left for the taxonomy phase; unknown_category softly validates it against
-- the divergence_taxonomy view.

CREATE VIEW IF NOT EXISTS adjudications AS SELECT NULL::JSON AS j WHERE false;
CREATE VIEW IF NOT EXISTS divergence_taxonomy AS SELECT NULL::VARCHAR AS category WHERE false;

CREATE TEMP TABLE _adj AS
SELECT
  j ->> 'candidate_id'                            AS candidate_id,
  j ->> 'verdict'                                 AS verdict,
  coalesce(j ->> 'context_judgment', 'ambiguous') AS context_judgment,
  j ->> 'note'                                    AS note,
  TRY_CAST(j ->> 'adjudicated_at' AS TIMESTAMP)   AS adjudicated_at
FROM adjudications
WHERE (j ->> 'candidate_id') IS NOT NULL;

CREATE TEMP TABLE _ce_mined AS
SELECT
  'ce-' || md5(c.candidate_id)                            AS event_id,
  c.date                                                  AS date,
  c.ts                                                    AS event_ts,
  a.adjudicated_at                                        AS adjudicated_at,
  'mined'                                                 AS channel,
  a.verdict                                               AS verdict,
  c.detector                                              AS detector,
  c.detector_version                                      AS detector_version,
  c.candidate_id                                          AS candidate_id,
  NULL::varchar                                           AS artifact_type,
  NULL::varchar[]                                         AS category,
  NULL::varchar                                           AS direction,
  NULL::varchar                                           AS magnitude,
  a.context_judgment                                      AS context_judgment,
  'organic'                                               AS selection,
  c.model_id                                              AS model_id,
  NULL::varchar                                           AS model_version,
  'lake:' || c.session_id || '/' || coalesce(c.prior_assistant_uuid, '') AS draft_ref,
  'lake:' || c.session_id || '/' || c.message_uuid        AS rewrite_ref,
  NULL::varchar                                           AS context_ref,
  CASE WHEN c.detector = 'tool_reject' THEN 'rejected' ELSE NULL END AS decision,
  NULL::varchar                                           AS distilled_rule_id,
  NULL::varchar                                           AS recurrence_cluster_id,
  NULL::varchar                                           AS intervention_ref,
  NULL::timestamp                                         AS bake_date,
  NULL::boolean                                           AS recurred_after_bake,
  NULL::bigint                                            AS observation_window_days,
  'shareable_abstraction'                                 AS privacy_scope,
  NULL::varchar                                           AS redaction_status,
  c.runtime                                               AS runtime,
  a.note                                                  AS note
FROM correction_candidates c
JOIN _adj a ON a.candidate_id = c.candidate_id
WHERE a.verdict = 'true_positive';

CREATE TEMP TABLE mine_out AS
SELECT b.*,
       (b.category IS NOT NULL AND NOT list_has_all(k.known, b.category)) AS unknown_category
FROM _ce_mined b, (SELECT list(category) AS known FROM divergence_taxonomy) k;
