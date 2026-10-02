# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.Stale do
  @moduledoc false
  # The stale?/1 calculation implementation: stale means the subject's
  # CURRENT projection digest differs from the one the fact recorded
  # (§7.4 normative 2). A fact without a recorded digest (crisp fact) and
  # an unknown current digest both read fresh — staleness is provable,
  # never assumed.
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, %{arguments: %{} = args}) do
    current = args[:current_digest]

    Enum.map(records, fn record ->
      recorded = record.subject_state_digest
      not is_nil(recorded) and not is_nil(current) and recorded != current
    end)
  end

  def calculate(records, _opts, %{arguments: nil}), do: Enum.map(records, fn _ -> false end)
end
