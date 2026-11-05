-- varve CI fixture: minimal Copilot session-store.db (the subset of tables
-- adapters/copilot.sql reads). Run with the target sqlite file ATTACHed
-- read-write as schema `cpdb` (see justfile `test`). cp-session-1 also has an
-- events.jsonl fixture; cp-session-db is DB-only (its events.jsonl is "gone"),
-- exercising the turns fallback.
CREATE TABLE cpdb.sessions (id VARCHAR, cwd VARCHAR, repository VARCHAR, summary VARCHAR, created_at VARCHAR);
CREATE TABLE cpdb.turns (id INTEGER, session_id VARCHAR, turn_index INTEGER, user_message VARCHAR,
                         assistant_response VARCHAR, timestamp VARCHAR);
CREATE TABLE cpdb.assistant_usage_events (
  id INTEGER, session_id VARCHAR, turn_index INTEGER, agent_id VARCHAR, model VARCHAR,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
  cache_write_tokens INTEGER, total_nano_aiu BIGINT, request_multiplier DOUBLE,
  duration_ms INTEGER, initiator VARCHAR, finish_reason VARCHAR, created_at VARCHAR);

INSERT INTO cpdb.sessions VALUES
  ('cp-session-1', '/home/runner/gitlab.com/testns/testrepo', NULL, 'Read ZCL_DEMO', '2023-05-01T10:00:00.000Z'),
  ('cp-session-db', '/home/runner/gitlab.com/testns/testrepo', NULL, 'Old session', '2023-05-02T09:00:00.000Z');

INSERT INTO cpdb.turns VALUES
  (1, 'cp-session-db', 0, 'list the transports', 'Here are the transports.', '2023-05-02T09:00:01.000Z'),
  (2, 'cp-session-db', 1, 'wrong system, use the dev box', 'Switching.', '2023-05-02T09:01:00.000Z');

-- input_tokens INCLUDES cache read+write (the adapter subtracts them): fresh input = 2.
INSERT INTO cpdb.assistant_usage_events VALUES
  (1, 'cp-session-1', 0, NULL, 'claude-sonnet-5', 1002, 50, 500, 500, 1000, 1.0, 900, 'user', 'tool_calls', '2023-05-01T10:00:02.000Z'),
  (2, 'cp-session-1', 1, 'agent-1', 'claude-haiku-4.5', 100, 10, 0, 0, 100, 0.33, 200, 'agent', 'stop', '2023-05-01T10:00:07.000Z');

CREATE TABLE cpdb.checkpoints (id INTEGER, session_id VARCHAR, checkpoint_number INTEGER, title VARCHAR,
  overview VARCHAR, history VARCHAR, work_done VARCHAR, technical_details VARCHAR,
  important_files VARCHAR, next_steps VARCHAR, created_at VARCHAR);
CREATE TABLE cpdb.session_files (id INTEGER, session_id VARCHAR, file_path VARCHAR, tool_name VARCHAR,
  turn_index INTEGER, first_seen_at VARCHAR);
CREATE TABLE cpdb.session_refs (id INTEGER, session_id VARCHAR, ref_type VARCHAR, ref_value VARCHAR,
  turn_index INTEGER, created_at VARCHAR);
INSERT INTO cpdb.checkpoints VALUES
  (1, 'cp-session-1', 1, 'Fix ZCL_DEMO', 'Overview', 'History', 'Work done', 'Tech', 'zcl_demo.abap', 'Next', '2023-05-01T10:05:00.000Z');
INSERT INTO cpdb.session_files VALUES
  (1, 'cp-session-1', '/home/runner/gitlab.com/testns/testrepo/zcl_demo.abap', 'edit', 0, '2023-05-01T10:00:03.000Z');
INSERT INTO cpdb.session_refs VALUES
  (1, 'cp-session-1', 'commit', 'abc1234', 1, '2023-05-01T10:06:00.000Z');
