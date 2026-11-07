-- Every detector fires on the fixture, the clarify carrier does not fire
-- tool_reject, and every noise marker in session-noise is excluded.
CREATE VIEW IF NOT EXISTS correction_candidates AS SELECT NULL::VARCHAR AS detector, NULL::VARCHAR AS runtime, NULL::VARCHAR AS message_uuid WHERE false;
CREATE VIEW IF NOT EXISTS operator_messages AS SELECT NULL::VARCHAR AS session_id WHERE false;
WITH want(detector, runtime) AS (
  VALUES ('tool_reject', 'claude-code'), ('tool_reject', 'opencode'), ('interrupt_redirect', 'claude-code'),
         ('lexical', 'claude-code'), ('lexical', 'opencode'), ('rewrite', 'claude-code')
)
SELECT 'detector ' || w.detector || ' produced no candidate for ' || w.runtime AS action
FROM want w
WHERE NOT EXISTS (SELECT 1 FROM correction_candidates c WHERE c.detector = w.detector AND c.runtime = w.runtime)
UNION ALL
SELECT 'the clarify carrier fired tool_reject'
WHERE EXISTS (SELECT 1 FROM correction_candidates WHERE detector = 'tool_reject' AND message_uuid = 'c0000000-0000-0000-0000-000000000019')
UNION ALL
SELECT 'test-session-noise has ' || n || ' operator message(s), want 1 (a noise rule stopped matching)'
FROM (SELECT count(*) AS n FROM operator_messages WHERE session_id = 'test-session-noise')
WHERE n <> 1;
