-- varve CI fixture: minimal opencode V1-contract SQLite store (session/message/
-- part), matching the shape adapters/opencode.sql documents. Run with the target
-- sqlite file already ATTACHed read-write as schema `oc` (see justfile `test`
-- recipe -- ATTACH needs a literal path, same constraint noted in
-- adapters/opencode.sql, so it happens in the recipe, not here). One session,
-- one user + one assistant message, one text part and one tool part -- enough to
-- exercise every column adapters/opencode.sql reads.

CREATE TABLE oc.session (
  id VARCHAR, parent_id VARCHAR, directory VARCHAR, version VARCHAR,
  agent VARCHAR, model VARCHAR, time_created BIGINT
);
CREATE TABLE oc.message (
  id VARCHAR, session_id VARCHAR, time_created BIGINT, data VARCHAR
);
CREATE TABLE oc.part (
  id VARCHAR, message_id VARCHAR, session_id VARCHAR, time_created BIGINT, data VARCHAR
);

INSERT INTO oc.session VALUES
  ('oc-session-1', NULL, '/home/runner/gitlab.com/testns/testrepo', '1.0.0', 'build',
   'claude-sonnet-5', 1785715200000);

INSERT INTO oc.message VALUES
  ('oc-msg-1', 'oc-session-1', 1785715200000,
   '{"role":"user"}'),
  ('oc-msg-2', 'oc-session-1', 1785715201000,
   '{"role":"assistant","modelID":"claude-sonnet-5","providerID":"anthropic","time":{"created":1785715201000,"completed":1785715202000},"cost":0.001,"tokens":{"input":100,"output":50,"reasoning":0,"cache":{"read":0,"write":0}}}');

INSERT INTO oc.part VALUES
  ('oc-part-1', 'oc-msg-1', 'oc-session-1', 1785715200000,
   '{"type":"text","text":"please write a hello function"}'),
  ('oc-part-2', 'oc-msg-2', 'oc-session-1', 1785715201500,
   '{"type":"text","text":"Sure thing."}'),
  ('oc-part-3', 'oc-msg-2', 'oc-session-1', 1785715201600,
   '{"type":"tool","callID":"call-1","tool":"bash","state":{"status":"completed","time":{"start":1785715201600,"end":1785715201700}}}');
