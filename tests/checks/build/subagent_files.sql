-- Subagent transcripts are read; the workflow journal beside them is not.
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS api_message_id WHERE false;
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id WHERE false;
SELECT 'subagent api calls: ' || n || ', want 2' AS action
FROM (SELECT count(*) AS n FROM api_calls WHERE api_message_id IN ('msg_sub_1', 'msg_sub_2'))
WHERE n <> 2
UNION ALL
SELECT 'the workflow journal produced a session'
FROM sessions WHERE session_id = 'not-a-transcript';
