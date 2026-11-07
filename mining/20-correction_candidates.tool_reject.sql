-- Detector tool_reject: a tool call the operator refused.
--   claude-code: the carrier row's tool results match a reject pattern and no
--     reject_exclude pattern. The match is on the result text, not on outcome:
--     outcome is the fact that the call was refused, and telling a clarifying
--     answer from a correction is this detector's judgment.
--   opencode: the call's outcome is denied.
-- Candidate id: md5 of detector, runtime, session and message, so adjudications
-- keep their keys. Version: the hash of this file.

CREATE TEMP TABLE _d AS
SELECT x.runtime, x.session_id, x.message_id AS message_uuid, x.prior_asst_uuid, x.ts,
       'tool_reject' AS detector,
       json_object('marker', 'tool_use_rejected', 'source', 'tool_result') AS features,
       x.model_id
FROM (SELECT runtime, session_id, result_message_id, string_agg(result_text, chr(10)) AS result_txt
      FROM tool_calls
      WHERE runtime = 'claude-code' AND result_message_id IS NOT NULL
      GROUP BY runtime, session_id, result_message_id) cc
JOIN operator_context x
  ON x.runtime = 'claude-code' AND x.session_id = cc.session_id AND x.message_id = cc.result_message_id
WHERE EXISTS (SELECT 1 FROM patterns p WHERE p.kind = 'reject' AND cc.result_txt ILIKE p.pattern)
  AND NOT EXISTS (SELECT 1 FROM patterns p WHERE p.kind = 'reject_exclude' AND cc.result_txt ILIKE p.pattern)
UNION ALL BY NAME
SELECT tc.runtime, tc.session_id, tc.message_id AS message_uuid,
       tc.message_id AS prior_asst_uuid, tc.started_at AS ts,
       'tool_reject' AS detector,
       json_object('marker', 'outcome_' || tc.outcome, 'source', 'outcome_column') AS features,
       NULL::varchar AS model_id
FROM tool_calls tc
WHERE tc.runtime = 'opencode' AND tc.outcome = 'denied';

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
