# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts do
  @moduledoc """
  The materialised-facts surface — **ticket S1-53** (TSET-SURFACE), on the
  judgment ledger (AST-88) and the registry (AST-87).

  ADR 0048 makes admitted facts the vocabulary of filters, search,
  segments and standing queries. This module and its fragments are that
  vocabulary's storage and derivation:

  - **`AshJudgments.Facts.Fragment`** — the facts table the HOST includes
    on its own resource (the same fragment pattern as the ledger): the
    RFC §7.4 shape (`subject`, `predicate`, `value` as JSON, scope,
    `subject_state_digest`, `valid_until`, `admission_grade`,
    `admission_id`, `superseded_by`) plus the freshness/current
    calculations the query surface reads, and the `subject`/`predicate`/
    `value` attributes the `AshRules.Evaluator.Set` resource path queries
    (S1-54's host contract).
  - **`AshJudgments.Facts.Materialiser`** — the write path: admissions and
    human verdicts materialise facts; review/omitted do not write; human
    entries win over automation; idempotent and replay-safe (the
    `:materialise` create accepts every field as input, law 2).
  - **`AshJudgments.Query`** — the derived read surface: tri-state
    membership (`in`/`out`/`unknown`), per-fact status (fresh/stale/
    expired), scope and grade floors, and the bounded `assess` selection
    of unknown/stale subjects.

  ## Membership is derived, never stored (RFC §7.4 normative 1)

  For a judged predicate, a subject is `in` when a current (not
  superseded), fresh (the subject's projection digest matches), unexpired
  fact in the actor's scope at or above the consumer's admission-grade
  floor says the predicate holds — `out` when it says it does not — and
  `unknown` otherwise: no fact, an `omitted` admission, a `review` task
  open, stale, or expired. No table stores a boolean that could lose the
  third value.

  ## The set-evaluator contract (S1-54)

  The fragment exposes `subject` (the composite subject term, as JSON —
  `{"type": ..., "id": ...}`), `predicate` (the string spelling — for
  judged predicates the question id, one namespace with crisp
  fact-schema names) and `value` as plain attributes, so
  `AshRules.Evaluator.Set.membership/4` runs over the host table
  directly.

  ## Value encoding ([L]1)

  Values are stored as SCALAR JSON first — `true`, `"urgent"`, `80` — so
  the set evaluator's data-layer filter and its strict
  `values_equal?/2` re-verification hit scalar probes directly. Wrapper
  maps only for genuinely composite values (extraction structs). The
  `AshJudgments.Facts.ScalarJson` type accepts any JSON-encodable term;
  the data layer's equality on the jsonb column remains a **superset**
  of strict equality (numeric coercion narrows; the evaluator
  re-verifies with `===`), which is the encoding discipline S1-54
  flagged. The `holds` column remains the tri-state surface's membership
  column (`Query.status/4`), not an ash_rules probe target.
  """

  @moduledoc since: "0.1.0"

  @graded [:grant, :person]

  @doc """
  The admission-grade ordering (ADR 0048 Q19): `:grant` (automation
  principal under a grant) is the floor; `:person` is the ceiling.
  Consumers state the MINIMUM grade they accept at request time; facts
  below the floor read as `unknown` for them.
  """
  @spec grade_at_least?(:grant | :person, :grant | :person) :: boolean()
  def grade_at_least?(grade, min) do
    Enum.find_index(@graded, &(&1 == grade)) >= Enum.find_index(@graded, &(&1 == min))
  end

  @doc "The grade floors, lowest first."
  @spec grades() :: [:grant | :person]
  def grades, do: @graded
end
