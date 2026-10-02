# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry do
  @moduledoc """
  The question registry DSL — **ticket AST-87** (CORE-REGISTRY).

  Law 4: every question — and every output shape — is a declaration.
  Questions are declared in a Spark extension on an Ash resource, typed by
  upstream answer types, given options drawn from constraints, versioned
  and content-hashed; the hash is the question's identity in the ledger.
  Because the question is a declaration, the manifest, the docs, the agent
  tooling and the audit pack all see the model surface like any other
  contract (Spark DSL sections are surfaced automatically).

      judgments do
        question :notes_follow_up do
          type AshAi.Evaluate.Noul
          instructions "Does the note describe a follow-up commitment?"
          version 1
          family :clinic_notes
          profile :laya_local
          pii :minimised
          state_projection MyApp.Projections.NoteText
        end
      end

  The declaration derives the identity at compile time
  (`AshJudgments.Registry.Canonical`):

  - `question_hash` — the judgment-record RFC §3.2 digest over the
    canonical JSON of exactly the identity object (answer type,
    instructions, criteria, ordered options, `state_contract`, version);
  - `question_id` — the §3.1 structural id
    `judgment:v0:<Module>#judgments/<name>`;
  - `state_contract` — the digest of the projection's declared `shape/0`
    output, or `nil` when none is declared (Q1's resolution: the declared
    shape is part of identity, a projection refactor that does not alter
    the shape does not mint a new question).

  It generates `judge_<name>` and `judge_<name>_matrix` actions delegating
  to upstream `AshAi.Actions.Evaluate` (the package ships no transport),
  with the profile resolved in the action path (law 3) and the state
  always the projection's output, never the raw input. Verifiers refuse
  contradictions at compile time (pii without a projection, must-record
  without a pin, options outside the source constraint) and the
  `priv/judgments/lock.json` check turns an un-versioned wording change
  into a compile error (AC-3).

  Family is deliberately outside the hash (Q3): it is the calibration
  grouping of law 5, and moving a question between families is a
  governance act recorded on the question record, not a new question.
  """

  @moduledoc since: "0.1.0"

  defstruct []

  use Spark.Dsl.Extension,
    sections: AshJudgments.Registry.Dsl.sections(),
    transformers: [
      AshJudgments.Registry.Transformers
    ],
    verifiers: [
      AshJudgments.Registry.Verifiers.VerifyOptionsSubset,
      AshJudgments.Registry.Verifiers.VerifyFamily,
      AshJudgments.Registry.Verifiers.VerifyPiiProjection,
      AshJudgments.Registry.Verifiers.VerifyRecordPin,
      AshJudgments.Registry.Verifiers.VerifyLock
    ]

  @doc "Every question declared on the resource."
  defdelegate questions(resource), to: AshJudgments.Registry.Info

  @doc "One declared question by name, or `nil`."
  defdelegate question(resource, name), to: AshJudgments.Registry.Info

  @doc "The question's content hash — its ledger identity — or `nil`."
  defdelegate hash(resource, name), to: AshJudgments.Registry.Info
end
