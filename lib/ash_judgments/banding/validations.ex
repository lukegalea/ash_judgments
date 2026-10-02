# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Banding.Validations.NonEmptyMatchedRules do
  @moduledoc false
  # matched_rule_ids empty is a REFUSAL, not a result (ADR 0041): a band
  # table that cannot say which row fired is not auditable.
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :matched_rule_ids) do
      [] ->
        {:error,
         field: :matched_rule_ids,
         message: "empty matched_rule_ids is a refusal, not a result (ADR 0041)"}

      _ids ->
        :ok
    end
  end
end

defmodule AshJudgments.Banding.Validations.FactValueAdmitOnly do
  @moduledoc false
  # fact_value is admit-only (§7.1): a review or omit banding cannot
  # propose a fact value.
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    band = Ash.Changeset.get_attribute(changeset, :band)
    fact_value = Ash.Changeset.get_attribute(changeset, :fact_value)

    if band != :admit and fact_value != nil do
      {:error, field: :fact_value, message: "fact_value is admit-only (§7.1)"}
    else
      :ok
    end
  end
end
