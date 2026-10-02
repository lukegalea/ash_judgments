# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.HumanVerdict.Fragment do
  @moduledoc """
  The human-verdict fragment: the fields and the `:record` create a host
  includes in its own resource (RFC §7.3; see `AshJudgments.HumanVerdict`).

  The create accepts every field as input — including `reviewer` and the
  model-answer snapshot — so AshEvents replay rebuilds the row from its
  inputs without consulting anything. Whose actor may claim which
  `reviewer` identity is the host's policy question (pure union grants on
  the host resource), never this package's.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    uuid_primary_key :id

    create_timestamp :recorded_at

    # The observation this verdict judges (RFC §7.3 observation_id; the
    # ticket names it judgment_id — same row, the ledger's `id`).
    attribute :judgment_id, :uuid, allow_nil?: false, public?: true

    # Denormalised from the observation (seams §1.8: override events carry
    # the question, state reference, model answer and version).
    attribute :question_hash, :string, allow_nil?: false, public?: true
    attribute :question_version, :integer, public?: true
    attribute :model_digest, :string, public?: true
    attribute :state_ref, :map, public?: true

    attribute :model_answer, :map,
      allow_nil?: false,
      public?: true,
      description: "The observation's answer snapshot: kind, value and distribution."

    attribute :model_version, :string, public?: true

    attribute :human_value, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The human's answer in the question's own answer space (option, level, true/false)."

    attribute :reason, :string, public?: true

    attribute :reviewer, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The reviewer as an input — the author of record; the host's policies gate who may claim it."

    attribute :blind?, :boolean,
      default: false,
      public?: true,
      description: "Whether the model's probability was hidden when the human answered."

    attribute :basis, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:review_task, :audit_sample, :labelling, :override]],
      default: :override,
      description:
        "Keeps the sample's selection visible (reviewed data is biased, ADR 0047 point 8)."
  end

  actions do
    create :record do
      description """
      Records a human verdict. Accepts every field as input — including the
      model-answer snapshot and the reviewer — so replay rebuilds the row
      from its inputs (RFC §6.1 applies to verdict records too).
      """

      accept [
        :judgment_id,
        :question_hash,
        :question_version,
        :model_digest,
        :state_ref,
        :model_answer,
        :model_version,
        :human_value,
        :reason,
        :reviewer,
        :blind?,
        :basis
      ]
    end

    defaults [:read]
  end
end
