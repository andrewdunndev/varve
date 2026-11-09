-- operator_messages and the detectors speak for the human operator: subagent
-- traffic, harness-written rows and bash output never count, and operator_context
-- holds one row per message. Fixture ids: test-session-scope, oc-session-scope,
-- oc-session-child.
CREATE VIEW IF NOT EXISTS operator_messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS message_uuid WHERE false;
CREATE VIEW IF NOT EXISTS correction_candidates AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS message_uuid, NULL::VARCHAR AS detector WHERE false;
CREATE VIEW IF NOT EXISTS operator_context AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::VARCHAR AS message_id WHERE false;
WITH want(label, n) AS (
  VALUES
  ('claude-code scope session keeps its two typed messages only',
   (SELECT (count(*) = 2 AND count(*) FILTER (WHERE message_uuid IN ('s0000000-0000-0000-0000-000000000001', 's0000000-0000-0000-0000-000000000005')) = 2)::int
    FROM operator_messages WHERE session_id = 'test-session-scope')),
  ('opencode scope session keeps its typed message only',
   (SELECT (count(*) = 1 AND count(*) FILTER (WHERE message_uuid = 'oc-msg-s1') = 1)::int
    FROM operator_messages WHERE session_id = 'oc-session-scope')),
  ('opencode child session has no operator message',
   (SELECT (count(*) = 0)::int FROM operator_messages WHERE session_id = 'oc-session-child')),
  ('the typed correction is the one candidate in the claude-code scope session',
   (SELECT (count(*) = 1 AND min(message_uuid) = 's0000000-0000-0000-0000-000000000005')::int
    FROM correction_candidates WHERE session_id = 'test-session-scope')),
  ('opencode scope and child sessions fire no detector',
   (SELECT (count(*) = 0)::int FROM correction_candidates WHERE session_id IN ('oc-session-scope', 'oc-session-child'))),
  ('operator_context carries is_sidechain and is_meta',
   (SELECT (count(*) FILTER (WHERE is_sidechain) > 0 AND count(*) FILTER (WHERE is_meta) > 0)::int
    FROM operator_context)),
  ('operator_context has one row per message',
   (SELECT (count(*) = count(DISTINCT (runtime, session_id, message_id)))::int FROM operator_context))
)
SELECT 'operator_scope: ' || label || ' (matched ' || n || ' rows, want 1)' AS action
FROM want WHERE n <> 1;
