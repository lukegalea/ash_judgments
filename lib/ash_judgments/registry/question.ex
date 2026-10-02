# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Question do
  @moduledoc """
  A declared question: what the host writes, plus what the package
  derives (the identity).

  The declared options are data; the derived ones — `options`,
  `state_contract`, `question_hash`, `question_id` — are computed at
  compile time by the transformer and are the question's identity in the
  ledger (judgment-record RFC §3.1/§3.2).
  """

  @moduledoc since: "0.1.0"

  defstruct [
    :name,
    :type,
    :constraints,
    :options_from,
    :source_enum_from,
    :abstain_option,
    :instructions,
    :criteria,
    :version,
    :family,
    :state_projection,
    :state_shape,
    :pii,
    :profile,
    :record,
    :ttl,
    :pin,
    :expose_as_tool?,
    :bpmn_callable?,
    # derived
    :options,
    :state_contract,
    :question_hash,
    :question_id,
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{}

  @doc false
  # The entity's `transform` hook: normalise the pin default (record :must
  # implies pin :required) so verifiers see one shape.
  def build(question) do
    pin =
      question.pin ||
        if question.record == :must, do: :required, else: :optional

    {:ok, %{question | pin: pin}}
  end
end
