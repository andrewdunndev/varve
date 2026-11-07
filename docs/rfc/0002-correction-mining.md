# RFC-0002: Correction mining

- **Status:** draft. Phase 1 (mechanical mining) is built: the mines in `mining/`,
  `just mine`, `just review`; the mine files carry the detectors, the candidate
  and event columns and the adjudication ledger format. Phases 2 and 3 are design
  only. This file keeps the method: what the mines do not say.
- **Date:** 2026-07-06

## Summary

Measure the gap between what the model produced and what the user corrected it
to, over time, by mining the lake. A mechanical pass over transcript structure
and content produces `correction_candidates`. The user adjudicates samples (true
or false positive, plus the context confound), which promotes candidates into
`correction_events`. The divergence taxonomy is derived from adjudicated events
and only then versioned as the controlled vocabulary.

The rulebook is the versioned instruction file where the user distils
corrections into standing rules. It stays distilled rules only; the analysis
feeds it, not the other way around.

The question is whether a correction lands once and holds, or is made again. A
hand-kept ledger records only what someone remembers to log, and that decays;
mining answers from the full lake history with no per-event effort.

### Channels

- **mined** (primary). Detection passes over the lake produce candidates.
- **adjudicated.** Review of mined candidates at analysis time. Adjudication
  supplies what cannot be mined: whether this is really a correction (the
  precision label) and `context_judgment` (did the model have what it needed to
  know better; the confound control, applied per event).
- **opt_in.** Deliberate draft-versus-rewrite diffs when the user chooses to make
  one. Rare; rides the same event schema.

There is no capture surface outside the lake.

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
the result as `mining/divergence_taxonomy.toml` v1, the controlled vocabulary for
`correction_events.category`. Then test it against the prior: the list derived
from the rulebook, kept in the same file and marked PRIOR. The comparison is itself
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
- Detector drift: `detector_version` on every candidate is the hash of the mine file;
  the marker list is data-home config and does not move it.

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

Nearest neighbours, none of which does the above: PRELUDE/CIPHER (Gao et al.,
NeurIPS 2024; learns latent preferences from user edits but optimizes outputs
rather than characterizing the gap; <https://arxiv.org/abs/2404.15269>); DRIFT
(2025); the machine-translation post-editing literature; Copilot acceptance-rate
studies (Ziegler et al., CACM 2024); annotation-queue tools such as Langfuse
(corrections as eval labels, not a preference-divergence stream); Cursor rules
and CLAUDE.md distillation (manual, unmeasured; "Beyond the Prompt", 2025).

