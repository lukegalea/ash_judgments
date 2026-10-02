# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.FamilyConfig do
  @moduledoc """
  The per-family policy data (law 5: thresholds are policy data, EARNED
  by calibration) — minimum n, per-class minimum, the target risk α,
  the max run age and the family's TTL override — read from host
  config, with package defaults:

      config :ash_judgments, :families, %{
        clinic_triage: %{min_n: 200, min_n_per_class: 40, ttl: 900}
      }

  Keys are family atoms (the registry questions' `family`). The values:

  - `min_n` — a band table may not be PROPOSED for the family below it
    (SYNTHESIS §2.2). Default: the design's e=0 row of the min-n table
    at α = 0.016 — 62 (`RiskControl.min_calibration_n/2`).
  - `min_n_per_class` — the per-class floor for choice families; `nil`
    (no floor) by default.
  - `alpha` — the target risk budget. Default 0.016 (error ≤ 2% at
    planning coverage ≥ 80%).
  - `max_age_days` — a run older than this does not certify a publish.
    Default 90.
  - `ttl` — the family's CACHE TTL override in seconds (the AST-89
    deferral): when set it overrides the questions' per-question `ttl`,
    which is how an operations family tunes freshness without touching
    the locked question declarations. `nil` (default) = the question's
    ttl governs.

  Everything is data: the verifier, the proposal trigger and the cache
  read these values — changing them is host configuration, never code.
  """

  @moduledoc since: "0.1.0"

  @default_alpha 0.016

  @defaults %{
    min_n: AshJudgments.Calibration.RiskControl.min_calibration_n(0, @default_alpha),
    min_n_per_class: nil,
    alpha: @default_alpha,
    max_age_days: 90,
    ttl: nil
  }

  @doc "The family's config, defaults merged under the host's overrides. Unknown families get the defaults."
  @spec fetch(atom() | String.t()) :: %{}
  def fetch(family) do
    families = Application.get_env(:ash_judgments, :families, %{})

    overrides =
      families
      |> Enum.find(fn {name, _} -> config_name(name) == config_name(family) end)
      |> case do
        {_name, overrides} when is_map(overrides) -> overrides
        _ -> %{}
      end

    Map.merge(@defaults, normalize(overrides))
  end

  @doc "The family's TTL override in seconds, or nil (the question's ttl governs)."
  @spec ttl(atom() | String.t()) :: pos_integer() | nil
  def ttl(family), do: fetch(family).ttl

  @doc "The family's target risk α."
  @spec alpha(atom() | String.t()) :: float()
  def alpha(family), do: fetch(family).alpha

  @doc "The family's minimum n (the proposal trigger's threshold)."
  @spec min_n(atom() | String.t()) :: pos_integer()
  def min_n(family), do: fetch(family).min_n

  defp config_name(name) when is_atom(name), do: Atom.to_string(name)
  defp config_name(name) when is_binary(name), do: name

  defp normalize(overrides) do
    Map.new(overrides, fn {k, v} -> {k, v} end)
  end
end
