# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.Calibration.Threshold do
  @moduledoc """
  A calibration run's conformal threshold at its family's α
  (`AshJudgments.Calibration.FamilyConfig.alpha/1`): the calibration
  fragment's `:threshold` calculation, a decimal string, or nil when the
  run earned none at that α. Display only: the proposal and the verifier
  read `conformal_thresholds` themselves.
  """
  @moduledoc since: "0.3.3"

  use Ash.Resource.Calculation

  alias AshJudgments.Calibration.FamilyConfig

  @impl true
  def load(_query, _opts, _context), do: [:family, :conformal_thresholds]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn run ->
      alpha = run.family |> FamilyConfig.alpha() |> Float.to_string()
      get_in(run.conformal_thresholds || %{}, [alpha, "threshold"])
    end)
  end
end
