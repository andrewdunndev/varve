-- tool_calls pairs each Claude Code result with its tool_use, gives every other
-- result block a row of its own, and maps outcome, arguments, result text and
-- the MCP name parts. Fixture ids are test-session-2023 lines and calls.
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS tool_use_id WHERE false;
WITH t AS (SELECT * FROM tool_calls),
carrier AS (SELECT 'c0000000-0000-0000-0000-000000000025' AS id),
want(label, n) AS (
  VALUES
  ('one row per result block in a carrier with three',
   (SELECT (count(*) = 3)::int FROM t, carrier WHERE t.result_message_id = carrier.id)),
  ('the first result pairs with its tool_use',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t6' AND message_id = 'c0000000-0000-0000-0000-000000000024'
      AND tool_name = 'Read' AND outcome = 'ok' AND result_text = 'first result'
      AND result_message_id = 'c0000000-0000-0000-0000-000000000025' AND arguments LIKE '%a.txt%')),
  ('a second result for one tool_use gets its own unpaired row',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t6' AND message_id IS NULL AND tool_name IS NULL
      AND started_at IS NULL AND result_text = 'second result')),
  ('a result with no tool_use gets an unpaired row',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_unpaired' AND message_id IS NULL AND tool_name IS NULL
      AND started_at IS NULL AND outcome = 'ok' AND result_text = 'orphan result')),
  ('a tool_use with no result has no outcome',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t7' AND tool_name = 'Bash' AND outcome IS NULL
      AND result_text IS NULL AND result_message_id IS NULL AND arguments LIKE '%ls%')),
  ('the rejection literal gives denied',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t1' AND outcome = 'denied'
      AND result_message_id = 'c0000000-0000-0000-0000-000000000003')),
  ('the interrupt literal gives cancelled',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t3' AND outcome = 'cancelled')),
  ('any other error result gives error',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t5' AND outcome = 'error' AND result_text = 'exit 1')),
  ('array-shaped result content reads as joined text, and an mcp name splits',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t2' AND outcome = 'ok' AND result_text = 'schema found'
      AND mcp_server = 'srv' AND mcp_tool = 'lookup')),
  ('a plain tool has no mcp parts',
   (SELECT count(*) FROM t WHERE tool_use_id = 'tool_t5' AND mcp_server IS NULL AND mcp_tool IS NULL)),
  ('opencode completed is ok with input and output',
   (SELECT count(*) FROM t WHERE runtime = 'opencode' AND tool_use_id = 'call-1' AND outcome = 'ok'
      AND arguments LIKE '%echo hi%' AND result_text = 'hi' AND result_message_id = message_id)),
  ('opencode rejected is denied',
   (SELECT count(*) FROM t WHERE runtime = 'opencode' AND tool_use_id = 'call-2' AND outcome = 'denied')),
  ('opencode error reads state.error',
   (SELECT count(*) FROM t WHERE runtime = 'opencode' AND tool_use_id = 'call-3' AND outcome = 'error' AND result_text = 'exit 1')),
  ('pi takes arguments from the toolCall block',
   (SELECT count(*) FROM t WHERE runtime = 'pi' AND tool_use_id = 'call-1' AND outcome = 'ok'
      AND arguments LIKE '%echo hi%' AND result_text = 'ok' AND result_message_id = 'e3'))
)
SELECT 'tool_pairing: ' || label || ' (matched ' || n || ' rows, want 1)' AS action
FROM want WHERE n <> 1;
