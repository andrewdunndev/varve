-- The new message columns hold the facts the record promises, one row each on
-- the fixture. Ids ending in a two-digit number are test-session-2023 lines.
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS message_id WHERE false;
WITH m AS (SELECT * FROM messages),
want(label, n) AS (
  VALUES
  ('operator row has origin operator',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000001' AND origin = 'operator' AND NOT interrupted)),
  ('assistant row has origin model',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000002' AND origin = 'model' AND NOT interrupted)),
  ('tool result carrier has origin tool_result and no text',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000003' AND origin = 'tool_result' AND text IS NULL)),
  ('an array-shaped result carrier has origin tool_result',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000014' AND origin = 'tool_result')),
  ('inline interrupt keeps its marker in text and is interrupted',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000005' AND interrupted
      AND text = '[Request interrupted by user]please also handle the empty input case in the parser')),
  ('bare interrupt is interrupted',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000007' AND interrupted AND origin = 'operator')),
  ('a marker inside a tool result makes the carrier interrupted',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000016' AND interrupted AND origin = 'tool_result')),
  ('an ordinary operator row is not interrupted',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000008' AND NOT interrupted)),
  ('assistant text blocks join with backslash and n',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000011'
      AND text = 'The parser reads the config file and validates every key against the schema' || chr(92) || 'nthen writes the result to the output directory')),
  ('assistant text skips tool_use blocks',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000002' AND text = 'I will run the build now.')),
  ('a harness-text row is still origin operator',
   (SELECT count(*) FROM m WHERE message_id = 'c0000000-0000-0000-0000-000000000026' AND origin = 'operator')),
  ('opencode text keeps reasoning parts in part order',
   (SELECT count(*) FROM m WHERE message_id = 'oc-msg-2' AND origin = 'model' AND interrupted IS NULL
      AND text = 'The request is small.' || chr(92) || 'nSure thing.')),
  ('opencode user row is origin operator',
   (SELECT count(*) FROM m WHERE message_id = 'oc-msg-1' AND origin = 'operator' AND text = 'please write a hello function')),
  ('pi joins text blocks and leaves interrupted NULL',
   (SELECT count(*) FROM m WHERE message_id = 'e2' AND origin = 'model' AND text = 'Sure thing.' AND interrupted IS NULL)),
  ('pi toolResult row has origin tool_result and no text',
   (SELECT count(*) FROM m WHERE message_id = 'e3' AND origin = 'tool_result' AND text IS NULL))
)
SELECT 'record_columns: ' || label || ' (matched ' || n || ' rows, want 1)' AS action
FROM want WHERE n <> 1;
