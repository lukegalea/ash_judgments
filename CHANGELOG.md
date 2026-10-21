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

- **The materialiser finds the current fact by scope (#13).** It looked
  the fact up by subject and predicate only and took the last row, on
  both fragments. An admission for one scope then revised, truncated or
  superseded another scope's fact (the revised row kept the other
  scope), was refused as `:kept_person_fact` because another scope held
  a person-grade fact, or returned `:unchanged` because another scope
  held the same value. The lookup now keys on `(subject, predicate,
  scope)`, comparing scopes by the same canonical hash the temporal
  fragment stores as `scope_hash`. An admission for a scope with no
  current fact creates one. Hosts change nothing; a temporal table whose
  rows were mis-scoped by the old lookup is rebuilt by replaying its
  admissions.
- **`Query.status/4` picks the strongest candidate (#10).** With several
  in-scope facts, the lowest-ranked decision won: a stale or expired fact
  beat an admitted one, and a grant-grade fact beat a person-grade one. A
  person-grade decision now decides first, then a grant-grade one, and an
  unknown reason only when no candidate decides.
- **The materialiser's default `effective_at` keeps microseconds (#11).**
  It was truncated to the second. Two admissions within one second then
  took the same instant, so the second replaced the first in place and
  the first kept no period in history; and a default admission landing
  before a period that opened earlier in the same second collided with it
  on the `WITHOUT OVERLAPS` identity.

### Features:

- **`AshJudgments.Facts.TemporalPrimaryKey`: a generated repair for a
  facts table without its primary key.** The fragment's key is
  `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`. A table created by a
  hand-written migration can lack it while the snapshot records it, and
  the migration generator cannot add it: it changes a primary key only
  when the snapshot's key changes, and then drops `<table>_pkey` first.
  Hosts in that state add the module's `repair_up/2` and `repair_down/2`
  as an `ash_postgres` custom statement on their facts resource and run
  `mix ash.codegen`. Hosts whose facts table was generated need nothing.

## [0.3.1] (2026-10-18)

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
