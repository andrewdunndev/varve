-- varve copilot: empty stand-in for session-store.db (schema `cpdb`) when the
-- Copilot home has events.jsonl files but no SQLite store. Carries only the columns
-- adapters/copilot.sql reads, so the adapter runs unchanged and contributes
-- events-only rows (no api_calls, no DB-only sessions).
CREATE SCHEMA IF NOT EXISTS cpdb;
CREATE TABLE cpdb.sessions (id VARCHAR, cwd VARCHAR, summary VARCHAR, created_at VARCHAR);
CREATE TABLE cpdb.turns (session_id VARCHAR, turn_index INTEGER, user_message VARCHAR,
                         assistant_response VARCHAR, timestamp VARCHAR);
CREATE TABLE cpdb.assistant_usage_events (
  id BIGINT, session_id VARCHAR, agent_id VARCHAR, model VARCHAR,
  input_tokens BIGINT, output_tokens BIGINT, cache_read_tokens BIGINT,
  cache_write_tokens BIGINT, total_nano_aiu BIGINT, request_multiplier DOUBLE,
  duration_ms BIGINT, initiator VARCHAR, finish_reason VARCHAR, created_at VARCHAR);
CREATE TABLE cpdb.checkpoints (session_id VARCHAR, checkpoint_number INTEGER, title VARCHAR,
  overview VARCHAR, history VARCHAR, work_done VARCHAR, technical_details VARCHAR,
  important_files VARCHAR, next_steps VARCHAR, created_at VARCHAR);
CREATE TABLE cpdb.session_files (session_id VARCHAR, file_path VARCHAR, tool_name VARCHAR,
  turn_index INTEGER, first_seen_at VARCHAR);
CREATE TABLE cpdb.session_refs (session_id VARCHAR, ref_type VARCHAR, ref_value VARCHAR,
  turn_index INTEGER, created_at VARCHAR);
