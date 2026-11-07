-- session-copy repeats lines of session.jsonl under a later-starting, lower-sorting
-- session id; the copy must count once, in the earliest-started session.
CREATE VIEW IF NOT EXISTS correction_candidates AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS message_uuid WHERE false;
CREATE VIEW IF NOT EXISTS operator_messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS message_uuid WHERE false;
WITH owners AS (
  SELECT 'candidates' AS src, session_id FROM correction_candidates WHERE message_uuid = '33333333-3333-3333-3333-333333333333'
  UNION
  SELECT 'operator_messages', session_id FROM operator_messages WHERE message_uuid = '33333333-3333-3333-3333-333333333333'
), got AS (
  SELECT coalesce(string_agg(src || ':' || session_id, ',' ORDER BY src), '') AS s FROM owners
)
SELECT 'copied message owned by [' || s || '], want test-session-1 once in each' AS action
FROM got
WHERE s <> 'candidates:test-session-1,operator_messages:test-session-1';
