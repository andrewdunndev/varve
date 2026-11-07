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

-- Detector coverage (2023, outside every stats window): a rejected tool part
-- (D1's forward-compatible branch), an errored one, and a lexical opener (D3).
INSERT INTO oc.session VALUES
  ('oc-session-2023', NULL, '/home/runner/gitlab.com/testns/testrepo', '1.0.0', 'build',
   'claude-sonnet-5', 1685577600000);

INSERT INTO oc.message VALUES
  ('oc-msg-3', 'oc-session-2023', 1685577600000,
   '{"role":"user"}'),
  ('oc-msg-4', 'oc-session-2023', 1685577601000,
   '{"role":"assistant","modelID":"claude-sonnet-5","providerID":"anthropic","time":{"created":1685577601000,"completed":1685577602000},"cost":0.001,"tokens":{"input":100,"output":50,"reasoning":0,"cache":{"read":0,"write":0}}}'),
  ('oc-msg-5', 'oc-session-2023', 1685577605000,
   '{"role":"user"}');

INSERT INTO oc.part VALUES
  ('oc-part-4', 'oc-msg-3', 'oc-session-2023', 1685577600000,
   '{"type":"text","text":"please list the project files"}'),
  ('oc-part-5', 'oc-msg-4', 'oc-session-2023', 1685577601500,
   '{"type":"text","text":"Here are the project files in the repository."}'),
  ('oc-part-6', 'oc-msg-4', 'oc-session-2023', 1685577601600,
   '{"type":"tool","callID":"call-2","tool":"bash","state":{"status":"rejected","time":{"start":1685577601600,"end":1685577601700}}}'),
  ('oc-part-7', 'oc-msg-4', 'oc-session-2023', 1685577601700,
   '{"type":"tool","callID":"call-3","tool":"bash","state":{"status":"error","time":{"start":1685577601700,"end":1685577601800}}}'),
  ('oc-part-8', 'oc-msg-5', 'oc-session-2023', 1685577605000,
   '{"type":"text","text":"no, use the other directory instead"}');
