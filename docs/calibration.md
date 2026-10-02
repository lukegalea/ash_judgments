<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# Calibration

**Law 5: thresholds are policy data, earned by calibration.** A band
table may not be PROPOSED for a family whose live accumulation is below
the family's minimum n; nothing is ever auto-certified — a person
certifies through `Banding.CertificationFragment`, and publication
stays ash_decisions' lifecycle (ADR 0041). The statistical basis is
conformal selective prediction with cost-aware deferral.

## The store (host-instantiated fragments)

Two fragments, on the host's repo, per the ledger/facts precedent:

- **`Calibration.Fragment`** — the §8.1 `CalibrationRun` record. The run
  key is `(family, question_hashes, model_digest, runtime_version,
  eval_set_hash, region)`; the fields are the body's contract: sample
  sizes (`n`, `n_per_class`), the metrics object (ALL numbers as
  decimal strings), `ece`/`brier`, `conformal_thresholds` (at target
  risk α, with the cost matrix), provenance (`:eval_set |
  :shadow_ledger`, `created_by`), the `observations_digest` (re-scoring
  reads the ledger, never re-infers), the `result`
  (`:proposed_table | :no_table | :regression` — negative results are
  kept, ADR 0047 point 7), the RECORDED `proposed_band_table` and the
  pre-registered `pass_bar`. Append-only; `:record` accepts every field
  as input and derives only the pure `record_hash` (id and timestamps
  excluded — identical inputs rebuild it identically, law 2).
- **`Calibration.SampleFragment`** — the per-family live accumulation
  (S1-62): one append-only row per labelled pair in a
  `(family, question_hash, model_digest, runtime_version, region)`
  slot; n is the slot's count. The gold label itself is payload-class —
  the row carries the pair's digest and the observation id; the label
  text lives in the zone's evaluation store, never in the record (§8.1).

## The metrics vocabulary

`Calibration.Metrics` — pure functions over `(prediction, gold)` pairs,
emitting the §8.1 decimal-string shape:

| Kind | Metrics |
|---|---|
| noul | tenth-width **reliability bins** (top bin closed at 1.0), **ECE**, **Brier** — golden-asserted to 1e-9 |
| choice | **per-class precision and recall**, accuracy |
| score | **level agreement** (exact) and **mean absolute error** — the ticket body leaves score metrics open; this is the minimal reading (flagged) |
| extraction | the [L]6 standard four: **exact_match**, **fabricated_citation**, **false_abstention**, **trap_wrong** — each nil when its denominator is zero (an absent metric is honest; a zero would be a claim) |

## The conformal arithmetic

`Calibration.RiskControl` — the design §3/§5 formulas as pure
functions, INTEROPERABLE with clinic-demo's
`ClinicDemo.EvalSets.RiskControl` (the reference implementation): the
min-n table (`n ≥ (e+1)/α − 1`; at α = 0.016: 62/124/187/249/312), the
tolerable-errors reading, the λ̂ quantile rule
(`λ̂ = inf {λ : (Σ Lᵢ(λ) + 1)/(n+1) ≤ α}`) and the audit alarm
(smallest k with `P(Binomial(m, α₀) ≥ k) ≤ 0.05` — 8 at m = 200,
α₀ = 0.02). The golden tests assert the design's worked numbers.

## The proposal trigger and the publish-time verifier

`Calibration.propose_band_table/3` — the n-threshold trigger: a run at
or above the family's `min_n` (and per-class floor, and its own
pre-registered pass bar) proposes the band table as DATA — the
thresholds come from the run's recorded conformal thresholds at the
family's α. **Thresholds are earned, never hand-set.** A refusal
returns structured findings (`:n_below_min` naming family, required n
and the digest; `:n_per_class_below_min`;
`:metrics_miss_pass_bar`) and writes nothing. Proposals are recorded on
the run and feed S1-62's review queue; certification and activation
are people's acts.

`Calibration.PublishVerifier.verify/4` — the check a host runs at
publish next to ash_decisions' overlap/completeness verifiers: a
PERSON's certification (status `:certified`), a run with n ≥ min_n and
per-class ≥ the floor, the SAME model digest/runtime version as the
definition, the same region, an eval_set_hash recorded, and a run age
≤ the family's `max_age_days`. Refusals name the family, the required
n and the pinned digest (AC-3's shape).

## Family config

`Calibration.FamilyConfig` reads
`config :ash_judgments, :families, %{family => %{...}}` over package
defaults — `min_n` (default 62, the design's e=0 row at α = 0.016),
`min_n_per_class` (nil), `alpha` (0.016 = error ≤ 2% at planning
coverage ≥ 80%), `max_age_days` (90), and the **family TTL override**
(the AST-89 deferral): `ttl:` seconds overrides the questions'
per-question ttl for cache freshness — an operations family tunes
freshness in host config without touching the locked question
declarations. The judge's cache lookups read the override first.

## Consumers

- **S1-62** (approval loop): accumulate through the samples fragment;
  when the slot's count crosses `min_n`, record a run and call
  `propose_band_table/3`; review the proposal; certify by a person;
  activate in ash_decisions.
- **S1-25** (the calibration-run harness): `mix ash_judgments.calibrate
  <family> [--source eval_set|shadow_ledger] [--dry-run]` loads the
  family's labelled pairs through a host seam, computes through
  `Metrics` and `RiskControl`, hands the run to `propose_band_table/3`,
  and records it through the fragment — a refused proposal is still a
  recorded `:no_table` run; a refusal never writes the proposal. The
  DMN rendering (`Calibration.ProposalDmn.render/2`) turns a recorded
  `proposed_band_table` into the publishable DMN XML document in the
  ash_decisions decision-table shape: a two-band UNIQUE table over the
  conformal score (`admit` at `≥ λ̂`, `review` below) with **no default
  rule** — an empty `matched_rule_ids` stays a refusal (ADR 0041).
  Rendering is pure and dependency-free; review, certification and
  publication stay the host's and ash_decisions' acts.

## The harness task (S1-25)

The task reads the family's labelled pairs and the store through two
host-supplied seams (stated in the task's moduledoc, the shadow
task's pattern):

    config :ash_judgments, :calibration_input, {MyApp.EvalSets, :load, []}
    # load(family, source) -> {:ok, input} | {:error, reason}

    config :ash_judgments, :calibration_store, MyApp.CalibrationRun
    # a host resource instantiating Calibration.Fragment

The input carries the `answer_kind`, the `Metrics` pair shapes, the
`RiskControl` scored pairs (`{score, gold_supports?}`), and the run
key's identity fields (question hashes, model version/digest, runtime
version, `eval_set_hash`, region). The task computes the §8.1 metrics
object, the conformal threshold at the family's α, records the run
with the proposal (or the `:no_table` negative result) on it, and
prints the DMN rendering. `--dry-run` prints all of it and records
nothing; a missing seam is an honest refusal, never a fabrication.

Statistical basis: the Feb 2026 Sci Reports clinical-triage paper and
arXiv 2605.20956 (conformal risk control, prevalence-shift risk) — the
eval-sets design's §4 sources.
