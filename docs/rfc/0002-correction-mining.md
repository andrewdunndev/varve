# RFC-0002 -- Correction mining

- **Status:** draft; **direction locked 2026-07-06 (operator decision): mining-first.**
  The earlier "week-1 capture minimum" (a hand-fed JSONL ledger kept beside the
  operator's standing voicing rules, a standing instruction in the operator's
  skill registry) is WITHDRAWN -- see History. Phase-1 mechanical mining is
  BUILT (`mining/corrections.sql`; `just mine` / `just review`); phases 2-3
  (classification, taxonomy derivation) stay draft.
- **Date:** 2026-07-06 (revised same day: capture-minimum resolved, then reversed)

## History

The first resolution of this RFC event-structured the *curated* channel: the operator
hand-appends a JSONL line to a ledger kept with the standing voicing rules each time
a correction is folded into a rule, against a taxonomy reverse-engineered from the
existing voicing rules. The operator rejected that shape on review, on two grounds
that reshape the design at the root:

1. **The ledger inverted the architecture.** The lake exists to do this analysis; its
   output should be small distilled primitives (a lean voicing rulebook), not a growing
   raw-event log maintained by hand. Hand capture also carries a compliance failure
   mode fatal to a longitudinal study -- it records only what someone remembers to log,
   and that decays -- and it is blind to history, while the lake already holds every
   correction ever made (message content is inline, an RFC-0001 decision made for
   exactly this).
2. **The seed taxonomy carried survivorship bias.** Voicing rules exist only for
   corrections that were noticed AND distilled. Deriving the vocabulary from them
   presupposes the answer. The taxonomy must be *mined from the data*, bottom-up; the
   voicing-derived list is demoted to a prior/hypothesis to test against.

What survives the reversal: the `correction_events` DDL (already channel-aware), the
non-identifying locus rule, the confound controls (`context_judgment`, selection,
model version), the durability test, and the novelty/prior-art positioning. What dies:
the skill-registry ledger, the voicing-rules capture convention (`docs/proposals/
voicing-capture.md`, removed), capture-time human judgment, and the taxonomy-as-seed.

## Summary

Turn the delta between model-default output and operator-corrected output into a
longitudinal, n-of-1 signal by **mining the lake**: (1) a mechanical detection pass
over transcript structure and content produces `correction_candidates`; (2) the
operator adjudicates samples at review time (true/false positive + the context
confound), promoting candidates into `correction_events`; (3) the divergence taxonomy
is derived bottom-up from adjudicated events and only then versioned as the controlled
vocabulary. The voicing rules stay distilled-rules-only; their git history supplies
the intervention timeline for the durability test.

## Motivation

Two goal-ladder rungs rest on this. G2 (harness-tuning adequacy) asks whether a
correction "lands once and holds" or is re-litigated; G3 (the team-level post-training
decision instrument) needs the same measurements aggregated. Mining makes the signal
retroactive (the full lake history is the corpus: 65 CC sessions / 142K messages at
lock time, plus opencode) and complete going forward at zero per-event operator
effort. The method is also where the genuine research novelty lives, and where the
confounds are, so it is written down before capture hardens around a weaker shape.

## Design

### Channel architecture (inverted from the withdrawn design)

- **mined (primary).** Detection passes over the lake produce candidates. Everything
  below.
- **adjudicated.** Operator review of mined candidates at analysis time -- not a
  standing capture habit. Adjudication supplies what cannot be mined: is this really
  a correction (precision label), and `context_judgment` (did the model have what it
  needed to know better -- the confound control, applied per adjudicated event).
- **opt_in.** Unchanged from the prior design: deliberate draft-vs-rewrite diffs when
  the operator chooses to make one. Rare; rides the same event schema.

There is NO capture surface in the skill registry. The operator's standing voicing
rules are untouched: they remain the distilled endpoint, and the analysis output
feeds them (lake -> primitives -> small rulebook), not the other way around.

### Phase 1 -- mechanical mining (build now)

Pure lake-side SQL (DuckDB over the existing views), no model in the loop, tuned for
**precision over recall**. Detectors, each emitting candidates with a `detector` id
and structural features:

- **Tool-decision rejections.** Claude Code: tool results carrying the rejection
  marker ("The user doesn't want to proceed with this tool use") and interrupt marker
  ("[Request interrupted by user...]"); already structured in `tool_calls`/`messages`.
  opencode: the native `decision` column (metadata, nearly free).
- **Interrupt-then-redirect.** A user interrupt followed by a user message within the
  same session -- the message following an interrupt is a correction with high prior.
- **Lexical correction openers.** User message directly following an assistant
  message, opening with a correction marker (no / don't / stop / not what / instead /
  actually / wrong / I meant / undo / revert -- versioned marker list in the adapter).
  Highest false-positive risk of the four; features carry the matched marker so
  precision is measurable per marker.
- **Rewrite detection.** User message with high token overlap against the preceding
  assistant message but not identical (operator restating/rewriting the model's text).
  Similarity via cheap set overlap (e.g. jaccard on token shingles) at phase 1;
  embedding similarity is phase 2.

Output: **`correction_candidates`** in the lake -- one row per (detector, locus):
`candidate_id`, `runtime`, `session_id`, `message_uuid` (the user/corrective message),
`prior_assistant_uuid` (the corrected draft's locus), `ts`, `date` (partition),
`detector`, `detector_version`, `features` (JSON: marker matched, overlap score,
decision value...), `model_id` of the corrected draft, `cwd`-derived attribution
(estate/harness -- reuse the W2 attribution rules). Candidates are **derived purely
from the lake**, so the table is rebuilt deterministically on ingest (no manifest
interaction; same rebuild discipline as the views). Confidentiality: candidates live
only in the local lake; loci are the non-identifying `lake:` form.

### Adjudication (the human loop, relocated from capture time to review time)

An analysis session surfaces a candidate sample (stratified by detector); the operator
labels each: `verdict` {true_positive | false_positive | unclear}, `context_judgment`
{had_context | lacked_context | ambiguous}, free `note` (role-level gloss). Labels are
appended to a JSONL adjudication ledger that lives **outside the repo at a configured
path** (`VARVE_ADJUDICATIONS`, default `<data_home>/adjudications.jsonl`) -- the
public-instrument rule keeps operator data out of git now that varve is public;
the ledger sits in the data home (outside `lake/`) so it survives a lake rebuild
(`just backfill` clears `lake/` only), and entries are non-identifying loci + labels only,
so I4/I5 hold regardless. `mining/corrections.sql` joins the ledger back to candidates
and promotes confirmed ones (`verdict=true_positive`) into `correction_events` (prior DDL
below) with `channel='mined'` + adjudication provenance. The adjudication line format --
one JSON object per line (the withdrawn design's hand-crib, relocated here):

```
{ "candidate_id":     "cand-<md5>",                            // REQUIRED; joins a candidate
  "verdict":          "true_positive|false_positive|unclear",  // REQUIRED
  "context_judgment": "had_context|lacked_context|ambiguous",  // the context confound
  "note":             "<role-level gloss only>",               // optional; no verbatim text/ids
  "adjudicated_at":   "2026-07-06T12:00:00" }                  // optional ISO timestamp
```

`mining/queries/adjudication_sample.sql` emits a ready-to-fill skeleton of this line per candidate.
For the review sitting itself, `just review` renders `<data_home>/review_round1.md`: one
section per flagged candidate with the FULL prior draft + FULL corrective message
dereferenced (round-0 found `context_judgment` largely un-inferable from a truncated
excerpt), the model's advisory suggestion (marked ADVISORY, not a verdict), and a copy-in
skeleton; a second part carries the recall-floor sample. Loci already in the ledger are
skipped so re-render is idempotent as the ledger grows. Output stays under the data home
(public-instrument rule); see `docs/queries.md` W7.

### Phase 2 -- assisted classification (after phase 1 validates)

The ambiguous middle (candidates neither structurally certain nor lexically obvious)
plus category labeling of confirmed events. In-session LLM labeling at n-of-1 volume
(same exposure class as the sessions that produced the content, same API path --
ADR-0004); graduate to local embeddings (weights on disk) + `vss` when volume demands.
Third-party embedding APIs remain excluded (ADR-0004). Nothing leaves the machine.

### Phase 3 -- taxonomy derivation (bottom-up)

Cluster adjudicated true-positive events (phase-2 labels/embeddings); name the
recurring divergence directions from what the clusters show; version the result as
`mining/divergence_taxonomy.csv` v1 -- the controlled vocabulary for
`correction_events.category`. THEN run the hypothesis test against the prior: the
voicing-derived 17-category list (kept in the same CSV, explicitly marked PRIOR) --
"does the mined taxonomy match the rules the operator bothered to write?" is itself a
result: categories in the prior but not the mine are either already-fixed or
rule-worthy-but-rare; categories in the mine but not the prior are corrections being
made without ever being distilled.

### Acceptance gates (precision is the load-bearing problem)

False positives poison the longitudinal signal, so phase 1 does not feed analysis
until measured:

- **G-precision:** per-detector precision on an adjudicated stratified sample (>=50
  candidates or all, whichever is smaller) -- gate at >=0.8 per detector; a detector
  below gate is demoted to phase-2 input, not dropped silently.
- **G-recall floor:** mining is precision-first, but measure the miss rate once:
  adjudicate a random sample of user-after-assistant messages NOT flagged by any
  detector; report detected/undetected correction ratio. This also seeds the
  selection-bias denominator (`selection` = sampled).
- **G-idempotence:** re-running the mining pass on an unchanged lake yields
  byte-identical candidates (same discipline as the core pipeline).

### DDL

`correction_candidates` -- new, columns above; partition `date`; rebuilt on ingest.

`correction_events` -- survives the withdrawn design unchanged in shape (one row per
confirmed event; partition `channel`/`date`; multi-label `category` as `VARCHAR[]`;
nullable `direction` override; NOT NULL `context_judgment`, `selection`,
`privacy_scope`; durability block `intervention_ref`/`bake_date`/
`recurred_after_bake`/`observation_window_days`; non-identifying loci only). Channel
values become {mined | adjudicated-implied-by-provenance | opt_in}: concretely,
promoted events carry `channel='mined'` + adjudication provenance columns
(`adjudicated_at`, `verdict`), and `channel='opt_in'` for deliberate diffs. The
`curated` channel value is retired with the ledger.

### Durability test (improved by the pivot)

The voicing rulebook's git history already timestamps every rule (each rule is a
baked intervention). Join mined event dates against rule commit dates:
`recurred_after_bake` falls out historically, with no new capture surface --
`intervention_ref` = the rule/commit, `bake_date` = its commit date. A parser over
`git log` for the voicing rulebook lands with phase 3 (it is an analysis input, not
a lake source).

### Method risks + mitigations (baked into the schema)

- Selection bias -> the G-recall floor sample is the denominator arm; `selection`
  {organic | sampled} on every event.
- Context confound -> mandatory `context_judgment` at adjudication; stratify analyses.
- Non-stationarity -> `model_id`/`model_version` recorded per candidate from the lake
  (the corrected draft's own API row -- more reliable than hand recall); treat version
  as covariate; re-baseline on model bumps.
- Small n -> divergence *category* as the unit of analysis, not the event;
  human-in-the-loop on distillation.
- Detector drift -> `detector_version` on every candidate; version the marker list.

### Novelty claims (from the prior-art sweep -- position honestly)

1. The measured object is the **delta itself** -- a taxonomy of divergence directions
   derived bottom-up from mined corrections (not asserted a priori).
2. A per-event **context-adjudication field** separating "genuine preference" from
   "model lacked context" -- no prior system operationalizes this confound.
3. Mining + adjudication + opt-in fusion over a multi-runtime local lake.
4. A **durability test** -- does baking a correction into a rule stop the divergence
   recurring ("land once and hold" as a measured closed loop), with the intervention
   timeline recovered from the rulebook's own git history.
5. n-of-1 longitudinal framing with model version as a controlled covariate.

**Honest caveats.** The team extension is the *least* novel part. The G3 saturation
criterion (PRD G3) is hypothesized-novel -- the prior-art sweep did not cover that
exact claim; verify before any external positioning.

**Prior art** (nearest neighbors, none does the above): PRELUDE/CIPHER (Gao et al.,
NeurIPS 2024 -- learns latent preferences from user edits but optimizes outputs rather
than characterizing the gap; <https://arxiv.org/abs/2404.15269>); DRIFT (2025);
machine-translation post-editing literature; Copilot acceptance-rate studies (Ziegler
et al., CACM 2024); industry annotation-queue tools (Langfuse etc., corrections as
eval labels, not a preference-divergence stream); Cursor rules / CLAUDE.md
distillation (manual, unmeasured -- "Beyond the Prompt", 2025).

## Unresolved questions

- Phase-1 marker list and overlap threshold: start values are the builder's call,
  measured by G-precision, tuned by adjudication rounds.
- Adjudication cadence: per analysis session vs batched; volume estimate sets it.
- Phase-2 trigger: candidate volume or precision-gap threshold that justifies
  assisted classification.
- Per-category signed direction (deferred from the withdrawn design, still deferred):
  promote `direction` to per-category structure only if the data shows opposing
  directions within single events.
- Whether `correction_candidates` should carry a short content EXCERPT column for
  adjudication ergonomics (lake-local only, never exported) or adjudication always
  dereferences the locus live. Builder proposes; confidentiality analysis in the MR.

## References

- PRD sections: W7 -- Correction mining; Goals G2, G3; Day-one action #4.
- Related: ADR-0004 (confidentiality: local-only pointers I5, no-identifier rule I4,
  embedding exclusion, LLM-labeling boundary), RFC-0001 (content inline -- the
  decision that makes mining possible; this RFC resolves its open `correction_events`
  DDL), PRD G3 (post-training instrument).
- In this repo: `mining/corrections.sql` (candidates + events adapter),
  `mining/divergence_taxonomy.csv` (voicing-derived PRIOR; canonical taxonomy is a
  phase-3 output), `mining/queries/corrections_candidates.sql` + `mining/queries/adjudication_sample.sql`.
  The adjudication ledger lives OUTSIDE the repo at a configured path
  (`VARVE_ADJUDICATIONS`, default `<data_home>/adjudications.jsonl`; public-instrument
  rule), created by the first adjudication round.
- External: PRELUDE/CIPHER <https://arxiv.org/abs/2404.15269>; Ziegler et al., CACM
  2024; Langfuse annotation queues; "Beyond the Prompt" (2025).
