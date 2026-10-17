<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## Unreleased

### Bug Fixes:

- **Compiles without `telemetry_metrics` (#6).**
  `AshJudgments.Telemetry.Metrics.definitions!/0` imported
  `Telemetry.Metrics`, which resolves at compile time, so a host without
  that optional dependency could not compile the package. The builders are
  now remote calls; `definitions/0` still returns
  `{:error, :telemetry_metrics_unavailable}` without the dependency. A new
  CI job (`scripts/no-optional-deps.sh`) compiles the package in a host
  that has none of its optional dependencies.
- **The facts changes declare `temporal_safe?/1` (#7).**
  `AshJudgments.Facts.Changes.DeriveSubject` and `DeriveScopeHash` derive
  their columns from the changeset's own inputs only, and now say so. Ash
  refused `:materialise` on a temporal facts host without
  `AshEvents.Events` (whose change wrapper declared safety on their
  behalf). Hosts can drop these two modules from
  `config :ash, :temporal_safe_modules`.

## [0.3.0]

### Features:

- **Temporal facts (AST-147/148).** `AshJudgments.Facts.TemporalFragment` —
  the facts contract with validity bookkeeping as a period: a revision
  splits the period at the admission's `effective_at` (`:revise`), an
  omission truncates it, uniqueness is a `WITHOUT OVERLAPS` exclusion on
  `(subject_type, subject_id, predicate, scope_hash)`, and a plain read is
  an as-of-now read. Supersession bookkeeping is deleted; the materialiser
  stays the sole writer and no normative moves.
- **The equivalence battery (AST-148).** `materialise(clear + replay) ≡
  materialise(live)` — periods included — and `Set.membership ↔
  Query.tri_state` (floor `:grant`), plus the six §4 temporal tests.
- **The materialiser's opt-in evidence assertion (Phase 4 C1).** A decision
  carrying `evidence_observation_id` (or a preloaded observation) is
  checked pre-transaction against the observation's recorded input hash; a
  mismatch raises `AshJudgments.Facts.Errors.EvidenceMismatch` and writes
  nothing. Absent references: the provable-only path is byte-identical.

### Deprecated:

- **`AshJudgments.Facts.Fragment`** — the legacy fragment is frozen: new
  hosts use `AshJudgments.Facts.TemporalFragment` (the README's "Replay
  your admissions" carries the migration story). Removal at 1.0, after one
  soak cycle on the temporal fragment; no behavior change on the legacy
  path until then.

### Documentation:

- README: "Replay your admissions" — the legacy→temporal migration story
  (the vpm_poc VPM-51 admission-ledger replay as the documented pattern;
  the C1 opt-in at cut-over; the C2 digest-periods pointer) and the
  `ash_events` fork-pin tracking note (upstream PR #104, issue #103).
