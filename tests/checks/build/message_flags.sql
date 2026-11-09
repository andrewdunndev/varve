-- is_meta and is_sidechain are carried per message, and a repeated source line
-- is one row. Fixture ids: test-session-scope and oc-session-scope/child.
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS message_id WHERE false;
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS tool_use_id WHERE false;
WITH want(label, n) AS (
  VALUES
  ('claude-code isMeta line is_meta',
   (SELECT count(*) FROM messages WHERE message_id = 's0000000-0000-0000-0000-000000000003' AND is_meta AND NOT is_sidechain)),
  ('claude-code typed line is neither meta nor sidechain',
   (SELECT count(*) FROM messages WHERE message_id = 's0000000-0000-0000-0000-000000000005' AND NOT is_meta AND NOT is_sidechain)),
  ('claude-code subagent line is_sidechain',
   (SELECT count(*) FROM messages WHERE message_id = 's1000000-0000-0000-0000-000000000001' AND is_sidechain AND NOT is_meta)),
  ('a repeated claude-code user line is one row',
   (SELECT (count(*) = 1)::int FROM messages WHERE message_id = 's0000000-0000-0000-0000-000000000005')),
  ('a repeated claude-code assistant line is one row',
   (SELECT (count(*) = 1)::int FROM messages WHERE message_id = 's0000000-0000-0000-0000-000000000006')),
  ('a repeated claude-code result line is one row',
   (SELECT (count(*) = 1)::int FROM messages WHERE message_id = 's0000000-0000-0000-0000-000000000007')),
  ('a repeated tool_use and result is one tool call',
   (SELECT (count(*) = 1)::int FROM tool_calls WHERE tool_use_id = 'tool_s1')),
  ('opencode message of only synthetic text is_meta',
   (SELECT count(*) FROM messages WHERE runtime = 'opencode' AND message_id = 'oc-msg-s3' AND is_meta AND NOT is_sidechain)),
  ('opencode typed message is neither meta nor sidechain',
   (SELECT count(*) FROM messages WHERE runtime = 'opencode' AND message_id = 'oc-msg-s1' AND NOT is_meta AND NOT is_sidechain)),
  ('opencode message in a child session is_sidechain',
   (SELECT count(*) FROM messages WHERE runtime = 'opencode' AND message_id = 'oc-msg-c1' AND is_sidechain AND NOT is_meta)),
  ('opencode assistant message is never meta',
   (SELECT (count(*) = 0)::int FROM messages WHERE runtime = 'opencode' AND role = 'assistant' AND is_meta)),
  ('pi messages are neither meta nor sidechain',
   (SELECT (count(*) = 0)::int FROM messages WHERE runtime = 'pi' AND (is_meta OR is_sidechain)))
)
SELECT 'message_flags: ' || label || ' (matched ' || n || ' rows, want 1)' AS action
FROM want WHERE n <> 1;
