# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Ledger.Validations.FamilyMatchesNamespace do
  @moduledoc false
  # The explore-tier widening's invariant (design errata [L]2, §7.4
  # normative 5): family is NULL exactly on an exploratory observation.
  # Null ties to the reserved namespace, so the widening cannot leak — a
  # declared question keeps its calibration grouping, and an exploratory
  # row can never carry a family (no family, no band table, no admission).
  use Ash.Resource.Validation

  alias AshJudgments.Exploration

  @impl true
  def validate(changeset, _opts, _context) do
    question_id = Ash.Changeset.get_attribute(changeset, :question_id)
    family = Ash.Changeset.get_attribute(changeset, :family)
    exploratory? = Exploration.exploratory?(question_id)

    cond do
      exploratory? and not is_nil(family) ->
        {:error,
         field: :family,
         message:
           "an exploratory observation carries no family (§7.4 n.5) — no family, no band table, no admission"}

      not exploratory? and is_nil(family) ->
        {:error,
         field: :family, message: "family is required outside the exploratory namespace (law 5)"}

      true ->
        :ok
    end
  end
end
