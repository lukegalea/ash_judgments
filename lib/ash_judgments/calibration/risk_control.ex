# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.RiskControl do
  @moduledoc """
  The conformal-risk-control arithmetic (the eval-sets design §3/§5) as
  pure functions — INTEROPERABLE with clinic-demo's
  `ClinicDemo.EvalSets.RiskControl`, the reference implementation of
  the same formulas: the min-n table, the tolerable-errors reading, the
  λ̂ quantile rule and the audit alarm. Same formulas, same worked
  examples; the golden tests assert agreement on the design's numbers.

  The bound being used. Conformal risk control for a monotone loss over
  selective auto-admission: the loss for calibration item i at threshold
  λ is `Lᵢ(λ) = 1` iff the model auto-admits i (score ≥ λ) **and** the
  gold label is not `supports`. The threshold is the fixed quantile rule

      λ̂ = inf { λ : ( Σᵢ Lᵢ(λ) + 1 ) / (n + 1) ≤ α }

  which — under exchangeability, monotone loss, the fixed rule (not a
  grid-search minimiser) and a marginal (not per-item) reading —
  guarantees `E[L(λ̂)] ≤ α`. To certify conditional error ≤ 2% at
  planning coverage ≥ 80%, set α = 0.8 × 2% = 0.016. Feasibility
  rearranges to `n ≥ (e + 1)/α − 1`.
  """

  @moduledoc since: "0.1.0"

  @doc """
  Smallest calibration n at which `e` observed wrong auto-admissions
  still meet budget `α`: `n ≥ (e + 1)/α − 1` (the design's worked table
  at α = 0.016: e 0→62, 1→124, 2→187, 3→249, 4→312).
  """
  def min_calibration_n(e, alpha) do
    ((e + 1) / alpha - 1) |> Float.ceil() |> trunc()
  end

  @doc """
  The most errors `e` a calibration run of `n` may show and still meet
  budget `α` (feasibility read the other way). nil when even zero
  errors exceed the budget.
  """
  def tolerable_errors(n, alpha) do
    case alpha * (n + 1) - 1 do
      bound when bound < 0 -> nil
      bound -> trunc(Float.floor(bound))
    end
  end

  @doc """
  The λ̂ quantile rule. `scored` is a list of `{score, gold_supports?}`;
  the loss is an error when `score ≥ λ` and the gold is not `supports`.
  Returns the smallest observed score λ with
  `(Σ Lᵢ(λ) + 1)/(n + 1) ≤ α`, or nil when no threshold meets the
  budget — including the zero-error case `1/(n + 1) > α` (the family
  cannot certify at this α at all: the bound doing its job).
  """
  def threshold(scored, alpha) do
    n = length(scored)

    scored
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find(fn lam ->
      errors = Enum.count(scored, fn {score, supports?} -> score >= lam and not supports? end)
      (errors + 1) / (n + 1) <= alpha
    end)
  end

  @doc """
  The audit alarm (design §5): the smallest `k` with
  `P(Binomial(m, α₀) ≥ k) ≤ level` (default 0.05). At m = 200, α₀ = 0.02
  this is 8 — the design's window rule.
  """
  def alarm_threshold(m, alpha0, level \\ 0.05)

  def alarm_threshold(m, alpha0, level) when m > 0 and alpha0 > 0 do
    1..m
    |> Enum.find(fn k -> binomial_ge(m, k, alpha0) <= level end)
  end

  def alarm_threshold(_m, _alpha0, _level), do: nil

  @doc "Exact-ish upper tail `P(Binomial(m, p) ≥ k)` by direct summation."
  def binomial_ge(m, k, p) when k <= m do
    Enum.reduce(k..m//1, 0.0, fn i, acc -> acc + binomial_term(m, i, p) end)
  end

  def binomial_ge(_m, _k, _p), do: 0.0

  defp binomial_term(m, i, p) do
    choose(m, i) * :math.pow(p, i) * :math.pow(1.0 - p, m - i)
  end

  defp choose(_n, r) when r <= 0, do: if(r == 0, do: 1, else: 0)

  defp choose(n, r) do
    r = min(r, n - r)

    Enum.reduce(1..r//1, 1, fn i, acc -> div(acc * (n - r + i), i) end)
  end
end
