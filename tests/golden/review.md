# varve -- correction adjudication review (round 1)

_Generated <ts>._ Candidates to adjudicate: 13 -- recall-floor sample: 15 (already-adjudicated loci are skipped).

For each candidate below: read the FULL prior draft and FULL corrective message, then copy the adjudication line into your adjudications ledger and fill `verdict` (true_positive | false_positive | unclear) and `context_judgment` (had_context | lacked_context | ambiguous). The ADVISORY line is the model's suggestion, NOT a verdict.

## Part 1 -- flagged candidates
### interrupt_redirect -- cand-0de46574d7884b7c94be8929f7373ce4

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000005`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000004`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"mode":"inline"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Understood, I will wait for further instructions from you.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
please also handle the empty input case in the parser

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-0de46574d7884b7c94be8929f7373ce4","verdict":"","context_judgment":"","note":""}

---
### interrupt_redirect -- cand-ad2b98bb6e875d0ea42f572d45490c72

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000008`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000006`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"mode":"next_message","interrupt_uuid":"c0000000-0000-0000-0000-000000000007"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Handled the empty input case in the parser as requested.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
use a streaming reader for the large inputs

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-ad2b98bb6e875d0ea42f572d45490c72","verdict":"","context_judgment":"","note":""}

---
### interrupt_redirect -- cand-e81eb69cb7581b8c9476866cbffa61e5

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000017`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000015`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"mode":"next_message","interrupt_uuid":"c0000000-0000-0000-0000-000000000016"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Running the formatter on the parser module now.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
try the fallback path instead of retrying the formatter

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-e81eb69cb7581b8c9476866cbffa61e5","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-431690e80664eb90718bf5913189be9b

- locus (corrective message): `lake:test-session-scope/s0000000-0000-0000-0000-000000000005`
- locus (prior draft): `lake:test-session-scope/s0000000-0000-0000-0000-000000000002`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"negation"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
The repository holds adapters and mining files.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
no, list only the adapters folder

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-431690e80664eb90718bf5913189be9b","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-4c09a86e542db6448befc592233461aa

- locus (corrective message): `lake:test-session-1/33333333-3333-3333-3333-333333333333`
- locus (prior draft): `lake:test-session-1/22222222-2222-2222-2222-222222222222`
- model_id: (unknown)
- attribution: unknown / unknown / 
- features: `{"marker":"negation"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Sure, here's a hello function using print().

--- CORRECTIVE OPERATOR MESSAGE (full) ---
no, use console.log instead

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-4c09a86e542db6448befc592233461aa","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-70b2f1be4874ff044cbdbfceaa164efc

- locus (corrective message): `lake:test-session-skill/k0000000-0000-0000-0000-000000000022`
- locus (prior draft): `lake:test-session-skill/k0000000-0000-0000-0000-000000000021`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"negation"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Appendix added.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
no, drop the appendix

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-70b2f1be4874ff044cbdbfceaa164efc","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-7912e6d22052c186c8f29199f27c0fb7

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000010`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000009`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"negation"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Switched the parser over to a streaming reader for large config files.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
no, keep the old reader and revert the streaming change

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-7912e6d22052c186c8f29199f27c0fb7","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-8287b422bf4dfbfcfc0612a427ba41ec

- locus (corrective message): `lake:oc-session-2023/oc-msg-5`
- locus (prior draft): `lake:oc-session-2023/oc-msg-4`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"negation"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Here are the project files in the repository.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
no, use the other directory instead

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-8287b422bf4dfbfcfc0612a427ba41ec","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-980d5a3d13b97acada432161dea638e0

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000021`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000020`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"wait"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Waiting for your clarification on the output format.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
okay wait, the parser should return an error instead of an empty list

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-980d5a3d13b97acada432161dea638e0","verdict":"","context_judgment":"","note":""}

---
### lexical -- cand-ad04fb862ec5d5d5a7f874768b719906

- locus (corrective message): `lake:test-session-skill/k0000000-0000-0000-0000-000000000008`
- locus (prior draft): `lake:test-session-skill/k0000000-0000-0000-0000-000000000006`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"negation"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Here is the draft report.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
no, use the short form

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-ad04fb862ec5d5d5a7f874768b719906","verdict":"","context_judgment":"","note":""}

---
### rewrite -- cand-cca0f9570ca491771bf51ba3487add5f

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000012`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000011`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"jaccard":0.7,"body_tokens":17,"prior_tokens":17}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
The parser reads the config file and validates every key against the schema
then writes the result to the output directory

--- CORRECTIVE OPERATOR MESSAGE (full) ---
the parser reads the config file and validates every key against the schema then writes results to the output folder

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-cca0f9570ca491771bf51ba3487add5f","verdict":"","context_judgment":"","note":""}

---
### tool_reject -- cand-1ae0ff0d34918b9eb64de4125dbbbb5b

- locus (corrective message): `lake:oc-session-2023/oc-msg-4`
- locus (prior draft): `lake:oc-session-2023/oc-msg-4`
- model_id: (unknown)
- attribution: unknown / unknown / 
- features: `{"marker":"outcome_denied","source":"outcome_column"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
Here are the project files in the repository.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
Here are the project files in the repository.

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-1ae0ff0d34918b9eb64de4125dbbbb5b","verdict":"","context_judgment":"","note":""}

---
### tool_reject -- cand-8ae03bfbb52a8fa87dc57b5457d209ac

- locus (corrective message): `lake:test-session-2023/c0000000-0000-0000-0000-000000000003`
- locus (prior draft): `lake:test-session-2023/c0000000-0000-0000-0000-000000000002`
- model_id: claude-sonnet-5
- attribution: unknown / unknown / 
- features: `{"marker":"tool_use_rejected","source":"tool_result"}`

**ADVISORY:** none (candidate not in the worksheet).

--- PRIOR ASSISTANT DRAFT (full) ---
I will run the build now.

--- CORRECTIVE OPERATOR MESSAGE (full) ---
The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"candidate_id":"cand-8ae03bfbb52a8fa87dc57b5457d209ac","verdict":"","context_judgment":"","note":""}

---
## Part 2 -- recall-floor sample (unflagged operator messages)

Adjudicate these to measure what mining MISSED (the recall floor). These operator messages were flagged by NO detector. Keyed on `message_uuid`; the skeleton fixes `"selection":"sampled"` so recall-floor labels stay distinguishable from precision-sample labels in the ledger.
### recall-floor -- a0000000-0000-0000-0000-000000000005

- locus: `lake:test-session-ny/a0000000-0000-0000-0000-000000000005`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
list the open tasks

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"a0000000-0000-0000-0000-000000000005","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- a0000000-0000-0000-0000-000000000001

- locus: `lake:test-session-ny/a0000000-0000-0000-0000-000000000001`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
summarize the build log

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"a0000000-0000-0000-0000-000000000001","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- 11111111-1111-1111-1111-111111111111

- locus: `lake:test-session-1/11111111-1111-1111-1111-111111111111`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
please write a hello function

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"11111111-1111-1111-1111-111111111111","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- k0000000-0000-0000-0000-000000000020

- locus: `lake:test-session-skill/k0000000-0000-0000-0000-000000000020`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
continue with the appendix

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"k0000000-0000-0000-0000-000000000020","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- a0000000-0000-0000-0000-000000000007

- locus: `lake:test-session-ny/a0000000-0000-0000-0000-000000000007`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
run the test suite

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"a0000000-0000-0000-0000-000000000007","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- oc-msg-1

- locus: `lake:oc-session-1/oc-msg-1`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
please write a hello function

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"oc-msg-1","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- oc-msg-s1

- locus: `lake:oc-session-scope/oc-msg-s1`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
summarize the repository layout

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"oc-msg-s1","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- n0000000-0000-0000-0000-000000000001

- locus: `lake:test-session-noise/n0000000-0000-0000-0000-000000000001`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
list the project files

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"n0000000-0000-0000-0000-000000000001","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- k0000000-0000-0000-0000-000000000001

- locus: `lake:test-session-skill/k0000000-0000-0000-0000-000000000001`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
build the report

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"k0000000-0000-0000-0000-000000000001","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- c0000000-0000-0000-0000-000000000001

- locus: `lake:test-session-2023/c0000000-0000-0000-0000-000000000001`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
build the parser module for the config file

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"c0000000-0000-0000-0000-000000000001","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- oc-msg-3

- locus: `lake:oc-session-2023/oc-msg-3`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
please list the project files

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"oc-msg-3","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- k0000000-0000-0000-0000-000000000017

- locus: `lake:test-session-skill/k0000000-0000-0000-0000-000000000017`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
thanks, that works

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"k0000000-0000-0000-0000-000000000017","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- a0000000-0000-0000-0000-000000000011

- locus: `lake:test-session-ny/a0000000-0000-0000-0000-000000000011`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
fix the failing test

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"a0000000-0000-0000-0000-000000000011","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- oc-msg-k1

- locus: `lake:oc-session-skill/oc-msg-k1`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
draft the changelog

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"oc-msg-k1","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
### recall-floor -- s0000000-0000-0000-0000-000000000001

- locus: `lake:test-session-scope/s0000000-0000-0000-0000-000000000001`
- attribution: unknown / unknown / 

--- OPERATOR MESSAGE (full) ---
summarize the repository layout

Adjudication line (copy into adjudications.jsonl; fill verdict + context_judgment):

    {"message_uuid":"s0000000-0000-0000-0000-000000000001","selection":"sampled","verdict":"","context_judgment":"","note":""}

---
