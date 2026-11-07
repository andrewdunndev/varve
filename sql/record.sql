-- The record contract: what each column of the four tables means.
--
-- Ids come from the source. Unknown is NULL, never zero or invented, except the
-- summed measures: tokens read 0 when the source records no usage, and cost_usd
-- reads 0 for an unpriced model (unpriced_model says so). A column's
-- meaning never changes; a new meaning gets a new name. Parsers report facts and
-- mining judges them. <rt>_* columns are nullable extensions a runtime may add.
-- Load this file to read the contract: SELECT * FROM record.
CREATE OR REPLACE VIEW record AS
SELECT * FROM (VALUES
  ('sessions', 'session_id', 'VARCHAR', 'The runtime''s own session id.'),
  ('sessions', 'runtime', 'VARCHAR', 'The runtimes.toml name of the runtime that wrote the session.'),
  ('sessions', 'cwd', 'VARCHAR', 'Working directory the session started in. NULL when the source holds none.'),
  ('sessions', 'harness', 'VARCHAR', 'Attribution result for cwd: the tool or repo the session ran in.'),
  ('sessions', 'estate', 'VARCHAR', 'Attribution result for cwd: the group of repos it belongs to. "unknown" when no rule matches.'),
  ('sessions', 'campaign', 'VARCHAR', 'Attribution result for cwd: the named stream of work. NULL when none applies.'),
  ('sessions', 'started_at', 'TIMESTAMP', 'Earliest timestamp the source records for the session, UTC for Claude Code and pi, build time zone for opencode.'),
  ('sessions', 'parent_session_id', 'VARCHAR', 'The session that spawned this one. NULL when the runtime records no chain.'),
  ('sessions', 'cc_version', 'VARCHAR', 'Claude Code version string. NULL for other runtimes.'),
  ('sessions', 'pi_version', 'VARCHAR', 'pi session format version. NULL for other runtimes.'),
  ('sessions', 'oc_version', 'VARCHAR', 'opencode version string. NULL for other runtimes.'),
  ('sessions', 'agent', 'VARCHAR', 'opencode agent name. NULL for other runtimes.'),
  ('sessions', 'date', 'DATE', 'Day of started_at in the same zone. Partition key.'),

  ('messages', 'message_id', 'VARCHAR', 'The source''s id for the line or entry. Not unique across sessions: a resumed session can copy lines.'),
  ('messages', 'session_id', 'VARCHAR', 'The session the message belongs to.'),
  ('messages', 'role', 'VARCHAR', 'The role the source records: user, assistant, or toolResult (pi only).'),
  ('messages', 'parent_id', 'VARCHAR', 'The message this one follows in the source''s own tree. NULL at a root.'),
  ('messages', 'is_sidechain', 'BOOLEAN', 'True for subagent traffic inside the parent session. Only Claude Code records it.'),
  ('messages', 'timestamp', 'TIMESTAMP', 'When the source stamped the message, UTC for Claude Code and pi, build time zone for opencode.'),
  ('messages', 'record_type', 'VARCHAR', 'The source''s own record type, unchanged.'),
  ('messages', 'api_message_id', 'VARCHAR', 'The provider''s message id. NULL when the source holds none.'),
  ('messages', 'origin', 'VARCHAR', 'Structure only. tool_result: the row carries a tool result. operator: any other user-role row. model: an assistant row. A user row can still be harness text; telling that apart is mining.'),
  ('messages', 'text', 'VARCHAR', 'The message''s text. A bare string, or the text blocks joined with the two characters backslash and n. Any leading interrupt marker is kept. opencode includes reasoning parts. NULL when the row has no text, and on pi toolResult rows.'),
  ('messages', 'interrupted', 'BOOLEAN', 'The interrupt marker appears in the row''s text or in a tool result it carries. Claude Code only: NULL for pi and opencode, which record no such signal a query reads.'),
  ('messages', 'runtime', 'VARCHAR', 'The runtimes.toml name. Partition key.'),
  ('messages', 'date', 'DATE', 'Day of the session''s started_at in the same zone. Partition key.'),

  ('api_calls', 'session_id', 'VARCHAR', 'The session the call belongs to.'),
  ('api_calls', 'message_id', 'VARCHAR', 'The assistant message that made the call. For a streamed call, the line with the most output.'),
  ('api_calls', 'api_message_id', 'VARCHAR', 'The provider''s message id. NULL for pi and opencode.'),
  ('api_calls', 'request_id', 'VARCHAR', 'The provider''s request id. NULL for pi and opencode.'),
  ('api_calls', 'timestamp', 'TIMESTAMP', 'When the call was made, UTC for Claude Code and pi, build time zone for opencode.'),
  ('api_calls', 'model', 'VARCHAR', 'The model id the source records.'),
  ('api_calls', 'provider', 'VARCHAR', 'The provider the source records.'),
  ('api_calls', 'input', 'BIGINT', 'Input tokens, excluding cache reads and writes. 0 when the source records no usage.'),
  ('api_calls', 'output', 'BIGINT', 'Output tokens. 0 when the source records no usage.'),
  ('api_calls', 'cache_read', 'BIGINT', 'Input tokens served from cache. 0 when the source records no usage.'),
  ('api_calls', 'cache_write', 'BIGINT', 'Input tokens written to cache. 0 when the source records no usage.'),
  ('api_calls', 'cost_usd', 'DOUBLE', 'The runtime''s inline cost when it is above zero, else tokens times pricing.toml, else zero with unpriced_model true.'),
  ('api_calls', 'unpriced_model', 'BOOLEAN', 'The model has no row in pricing.toml.'),
  ('api_calls', 'runtime', 'VARCHAR', 'The runtimes.toml name. Partition key.'),
  ('api_calls', 'date', 'DATE', 'Day of the session''s started_at in the same zone. Partition key.'),

  ('tool_calls', 'session_id', 'VARCHAR', 'The session the call belongs to.'),
  ('tool_calls', 'message_id', 'VARCHAR', 'The message that holds the call. Claude Code: the assistant line; pi: the toolResult entry; opencode: the message of the part. NULL for a Claude Code result with no tool_use.'),
  ('tool_calls', 'tool_use_id', 'VARCHAR', 'The source''s id for the call.'),
  ('tool_calls', 'tool_name', 'VARCHAR', 'The tool''s name as the source records it. NULL for a Claude Code result with no tool_use.'),
  ('tool_calls', 'started_at', 'TIMESTAMP', 'When the call began, UTC for Claude Code and pi, build time zone for opencode. Claude Code and pi stamp the message, opencode the tool itself. NULL when unknown.'),
  ('tool_calls', 'ended_at', 'TIMESTAMP', 'When the call ended, UTC for Claude Code and pi, build time zone for opencode. opencode only.'),
  ('tool_calls', 'duration_ms', 'BIGINT', 'ended_at minus started_at in milliseconds. opencode only.'),
  ('tool_calls', 'outcome', 'VARCHAR', 'What happened: ok, error, denied (the operator refused the call), cancelled (the operator interrupted it), running. NULL when the source records no result.'),
  ('tool_calls', 'arguments', 'VARCHAR', 'The call''s input as JSON text. NULL when the source holds none.'),
  ('tool_calls', 'result_text', 'VARCHAR', 'The result as text: a string result as is, an array result as its text items joined with the two characters backslash and n. opencode: the output, else the error. NULL when none. Output a runtime stores in a side file reads as the stub the source keeps.'),
  ('tool_calls', 'result_message_id', 'VARCHAR', 'The message that carries the result: the messages row whose origin is tool_result for Claude Code. NULL when there is no result.'),
  ('tool_calls', 'runtime', 'VARCHAR', 'The runtimes.toml name. Partition key.'),
  ('tool_calls', 'date', 'DATE', 'Day of the session''s started_at in the same zone. Partition key.')
) t(table_name, column_name, type, meaning);
