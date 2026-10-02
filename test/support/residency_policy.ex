# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.ResidencyPolicy do
  @moduledoc """
  A configurable policy for the profile tests: reads its decisions from
  `config :ash_judgments, :test_residency_decisions` (a map of
  `residency => boolean`, defaulting to the package's deny-sub-processor
  posture). The AC-3 property iterates every decision this policy can
  return; keeping the decision table as data makes the enumeration exact.
  """

  @behaviour AshJudgments.ResidencyPolicy

  @impl AshJudgments.ResidencyPolicy
  def allow?(_tenant, residency, _family) do
    :ash_judgments
    |> Application.get_env(:test_residency_decisions, %{})
    |> Map.get(residency, residency == :in_cluster)
  end
end
