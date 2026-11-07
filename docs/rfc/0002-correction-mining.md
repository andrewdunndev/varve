# RFC-0002: Correction mining

- **Status:** draft. Phase 1 (mechanical mining) is built: `mining/corrections.sql`,
  `just mine`, `just review`. Phases 2 and 3 (classification, taxonomy
  derivation) are design only.
- **Date:** 2026-07-06

## Summary

Measure the gap between what the model produced and what the user corrected it
to, over time, by mining the lake. A mechanical detection pass over transcript
structure and content produces `correction_candidates`. The user adjudicates
samples at review time (true or false positive, plus the context confound),
which promotes candidates into `correction_events`. The divergence taxonomy is
derived from adjudicated events and only then versioned as the controlled
vocabulary.

Throughout, the rulebook is the versioned instruction file where the user
distils corrections into standing rules. It stays distilled rules only; the
analysis feeds it, not the other way around.

## Motivation

Does a correction land once and hold, or is it made again? Mining answers that
from the full lake history (message content is inline, an RFC-0001 decision made
for this) and keeps answering as the lake grows, with no per-event effort from
the user. A hand-kept ledger records only what someone remembers to log, and
that decays. The method is where the research novelty lives and where the
confounds are, so it is written down before capture hardens around a weaker
shape.

## Design

### Channels

- **mined** (primary). Detection passes over the lake produce candidates.
- **adjudicated.** Review of mined candidates at analysis time. Adjudication
  supplies what cannot be mined: whether this is really a correction (the
  precision label) and `context_judgment` (did the model have what it needed to
  know better; the confound control, applied per event).
- **opt_in.** Deliberate draft-versus-rewrite diffs when the user chooses to make
  one. Rare; rides the same event schema.

There is no capture surface outside the lake.

### Phase 1: mechanical mining

Pure lake-side SQL (DuckDB over the existing views), no model in the loop, tuned
for precision over recall. Each detector emits candidates with a `detector` id
and structural features:

- **Tool-decision rejections.** Claude Code: tool results carrying the rejection
  marker ("The user doesn't want to proceed with this tool use") and the
  interrupt marker ("[Request interrupted by user...]"), already structured in
  `tool_calls` and `messages`. opencode: the native tool `outcome`.
- **Interrupt-then-redirect.** A user interrupt followed by a user message within
  the same session. The message after an interrupt is a correction with high
  prior.
- **Lexical correction openers.** A user message directly following an assistant
  message, opening with a correction marker (no / don't / stop / not what /
  instead / actually / wrong / I meant / undo / revert; the marker list is
  versioned in the adapter). Highest false-positive risk of the four; features
  carry the matched marker so precision is measurable per marker.
- **Rewrite detection.** A user message with high token overlap against the
  preceding assistant message but not identical: the user restating or rewriting
  the model's text. Similarity is cheap set overlap (jaccard on token shingles)
  in phase 1; embedding similarity is phase 2.

Output: `correction_candidates` in the lake, one row per (detector, locus):
`candidate_id`, `runtime`, `session_id`, `message_uuid` (the corrective message),
`prior_assistant_uuid` (the corrected draft's locus), `ts`, `date` (partition),
`detector`, `detector_version`, `features` (JSON: marker matched, overlap score,
decision value), `model_id` of the corrected draft, and `cwd`-derived attribution
(estate and harness, from the attribution rules). Candidates derive purely from
the lake, so the table is rebuilt deterministically on ingest with no manifest
interaction. Candidates live only in the local lake; loci use the non-identifying
`lake:` form.

### Adjudication

An analysis session surfaces a candidate sample, stratified by detector. The user
labels each: `verdict` {true_positive | false_positive | unclear},
`context_judgment` {had_context | lacked_context | ambiguous}, and a free `note`
(role-level gloss). Labels append to a JSONL ledger outside the repo at a
configured path (`VARVE_ADJUDICATIONS`, default `<data_home>/adjudications.jsonl`).
The ledger sits in the data home outside `lake/`, so it survives a lake rebuild
(`just backfill` clears `lake/` only), and it holds non-identifying loci and
labels only, so I4 and I5 hold. `mining/corrections.sql` joins the ledger back to
candidates and promotes `verdict=true_positive` rows into `correction_events`
with `channel='mined'` and adjudication provenance. One JSON object per line:

```
{ "candidate_id":     "cand-<md5>",                            // REQUIRED; joins a candidate
  "verdict":          "true_positive|false_positive|unclear",  // REQUIRED
  "context_judgment": "had_context|lacked_context|ambiguous",  // the context confound
  "note":             "<role-level gloss only>",               // optional; no verbatim text/ids
  "adjudicated_at":   "2026-07-06T12:00:00" }                  // optional ISO timestamp
```

`mining/queries/adjudication_sample.sql` emits a ready-to-fill skeleton of this
line per candidate. For the review sitting, `just review` renders
`<data_home>/review_round1.md`: one section per flagged candidate with the full
prior draft and full corrective message dereferenced (a truncated excerpt leaves
`context_judgment` hard to judge), the model's suggestion marked ADVISORY, and a
copy-in skeleton; a second part carries the recall-floor sample. Loci already in
the ledger are skipped, so re-rendering is idempotent as the ledger grows.
Output stays under the data home. See `docs/queries.md`.

### Phase 2: assisted classification

After phase 1 validates: the ambiguous middle (candidates neither structurally
certain nor lexically obvious) plus category labelling of confirmed events.
In-session LLM labelling at single-user volume, the same exposure class and API
path as the sessions that produced the content (ADR-0004); graduate to local
embeddings (weights on disk) with `vss` when volume demands. Third-party
embedding APIs stay excluded (ADR-0004). Nothing leaves the machine.

### Phase 3: taxonomy derivation

Cluster adjudicated true-positive events using the phase-2 labels or embeddings,
name the recurring divergence directions from what the clusters show, and version
the result as `mining/divergence_taxonomy.csv` v1, the controlled vocabulary for
`correction_events.category`. Then test it against the prior: the list derived
from the rulebook, kept in the same CSV and marked PRIOR. The comparison is itself
a result. Categories in the prior but not the mine are either already fixed or
rule-worthy but rare; categories in the mine but not the prior are corrections
being made without ever being distilled.

### Acceptance gates

False positives poison the longitudinal signal, so phase 1 does not feed analysis
until measured:

- **G-precision:** per-detector precision on an adjudicated stratified sample
  (>=50 candidates or all, whichever is smaller); gate at >=0.8 per detector. A
  detector below gate becomes phase-2 input rather than being dropped silently.
- **G-recall floor:** measure the miss rate once. Adjudicate a random sample of
  user-after-assistant messages no detector flagged and report the ratio of
  detected to undetected corrections. This also seeds the selection-bias
  denominator (`selection` = sampled).
- **G-idempotence:** re-running the mining pass on an unchanged lake yields
  byte-identical candidates.

### DDL

`correction_candidates`: columns above; partition `date`; rebuilt on ingest.

`correction_events`: one row per confirmed event; partition `channel`/`date`;
multi-label `category` as `VARCHAR[]`; nullable `direction` override; NOT NULL
`context_judgment`, `selection`, `privacy_scope`; durability block
`intervention_ref`/`bake_date`/`recurred_after_bake`/`observation_window_days`;
non-identifying loci only. `channel` is `mined` (with the adjudication provenance
columns `adjudicated_at` and `verdict`) or `opt_in` for deliberate diffs.

### Durability test

The rulebook's git history timestamps every rule, and each rule is a baked
intervention. Join mined event dates against rule commit dates and
`recurred_after_bake` falls out: `intervention_ref` is the rule or commit,
`bake_date` its commit date. A parser over the rulebook's `git log` lands with
phase 3; it is an analysis input, not a lake source.

### Method risks and mitigations

- Selection bias: the G-recall floor sample is the denominator arm; `selection`
  {organic | sampled} on every event.
- Context confound: mandatory `context_judgment` at adjudication; stratify
  analyses on it.
- Non-stationarity: `model_id`/`model_version` recorded per candidate from the
  corrected draft's own API row; treat version as a covariate and re-baseline on
  model bumps.
- Small n: the divergence category is the unit of analysis, not the event; a
  human stays in the loop on distillation.
- Detector drift: `detector_version` on every candidate; the marker list is
  versioned.

### Novelty and prior art

1. The measured object is the delta itself: a taxonomy of divergence directions
   derived from mined corrections, not asserted a priori.
2. A per-event context-adjudication field separating "genuine preference" from
   "model lacked context".
3. Mining, adjudication and opt-in fused over a multi-runtime local lake.
4. A durability test: does baking a correction into a rule stop the divergence
   recurring, with the intervention timeline recovered from the rulebook's own
   git history.
5. Single-user longitudinal framing with model version as a controlled
   covariate.

The team extension is the least novel part. The saturation criterion in the PRD
is hypothesised novel; the prior-art sweep did not cover that exact claim.
Verify before any external positioning.

Nearest neighbours, none of which does the above: PRELUDE/CIPHER (Gao et al.,
NeurIPS 2024; learns latent preferences from user edits but optimizes outputs
rather than characterizing the gap; <https://arxiv.org/abs/2404.15269>); DRIFT
(2025); the machine-translation post-editing literature; Copilot acceptance-rate
studies (Ziegler et al., CACM 2024); annotation-queue tools such as Langfuse
(corrections as eval labels, not a preference-divergence stream); Cursor rules
and CLAUDE.md distillation (manual, unmeasured; "Beyond the Prompt", 2025).

## Unresolved questions

- Phase-1 marker list and overlap threshold: start values are a judgement call,
  measured by G-precision and tuned by adjudication rounds.
- Adjudication cadence: per analysis session or batched; the volume estimate
  sets it.
- Phase-2 trigger: the candidate volume or precision gap that justifies assisted
  classification.
- Per-category signed direction: promote `direction` to per-category structure
  only if the data shows opposing directions within single events.
- Whether `correction_candidates` should carry a short content excerpt column
  for adjudication ergonomics (lake-local only, never exported) or adjudication
  always dereferences the locus live. Needs a confidentiality analysis with the
  change.

## References

- PRD sections: Architecture; Goals.
- Related: ADR-0004 (confidentiality: local-only pointers I5, no-identifier rule
  I4, embedding exclusion, LLM-labelling boundary), RFC-0001 (content inline, the
  decision that makes mining possible; this RFC resolves its open
  `correction_events` DDL).
- In this repo: `mining/corrections.sql` (candidates and events adapter),
  `mining/divergence_taxonomy.csv` (the PRIOR; the canonical taxonomy is a
  phase-3 output), `mining/queries/corrections_candidates.sql`,
  `mining/queries/adjudication_sample.sql`. The adjudication ledger lives outside
  the repo at `VARVE_ADJUDICATIONS` (default `<data_home>/adjudications.jsonl`),
  created by the first adjudication round.
- External: PRELUDE/CIPHER <https://arxiv.org/abs/2404.15269>; Ziegler et al.,
  CACM 2024; Langfuse annotation queues; "Beyond the Prompt" (2025).
