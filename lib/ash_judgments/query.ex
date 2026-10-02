# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Query do
  @moduledoc """
  The derived query surface (S1-53): tri-state membership and per-fact
  status over the facts table, and the bounded `assess` selection.

  Everything here READS. Membership is derived, never stored (RFC §7.4
  normative 1): `in` when a current, fresh, unexpired, in-scope fact at
  or above the consumer's grade floor says the predicate holds; `out`
  when it says it does not; `unknown` otherwise — no fact, an omitted
  admission, an open review, stale, expired, or below the grade floor.
  `unknown` is never folded into either side (ADR 0048's three-valued
  law).

  ## Options

  - `:scope` — the fact scope to read in (`nil` = subject-alone facts).
  - `:min_grade` — the consumer's admission-grade floor (Q19):
    `:grant` (the default) accepts every admitted fact; `:person`
    accepts only person-admitted ones.
  - `:current_digests` — `%{subject => digest}`: each subject's current
    projection digest (kept by the host per §7.4 normative 2). A fact
    whose recorded digest differs is **stale** — it reads as `unknown`
    and is queued for reassessment (`assess/3`); it is not deleted.
  - `:limit` — the assess bound (default 100).
  - `:priority` — an MFA seam (`{m, f, a}` called with each candidate)
    scoring the assess order (S1-56's retrieval-scored priority hooks in
    here later; the package builds no retrieval).

  The facts resource comes from `config :ash_judgments, :facts` (or the
  `:resource` option).
  """

  @moduledoc since: "0.1.0"

  @assess_default_limit 100

  @type membership() :: %{in: [term()], out: [term()], unknown: [{term(), atom()}]}

  @doc """
  The three-valued membership of ONE subject under ONE predicate:
  `{:in | :out | :unknown, fact_or_reason}` — the fact accompanies an
  `:in`/`:out` verdict; an `:unknown` carries the reason
  (`:no_fact | :below_grade | :stale | :expired | :superseded`).
  """
  @spec status(module(), term(), String.t(), keyword()) ::
          {:in, term()} | {:out, term()} | {:unknown, :no_fact | :below_grade | :stale | :expired}
  def status(resource, subject, predicate, opts \\ []) do
    facts = current_facts(resource, subject, predicate, opts)

    case Enum.filter(facts, &in_scope?(&1, opts)) do
      [] ->
        {:unknown, :no_fact}

      candidates ->
        current_digest = current_digest(opts, subject)

        candidates
        |> Enum.map(&decide(&1, opts, current_digest))
        |> Enum.sort_by(&grade_rank/1)
        |> Enum.find(& &1) || {:unknown, :no_fact}
    end
  end

  @doc """
  The three-valued partition over a list of subjects under ONE predicate:
  `%{in: [...], out: [...], unknown: [{subject, reason}]}` — disjoint,
  covering the given subjects (ADR 0048: membership is three-valued and
  stays three-valued).
  """
  @spec tri_state(module(), [term()], String.t(), keyword()) :: membership()
  def tri_state(resource, subjects, predicate, opts \\ []) do
    opts = Keyword.put_new(opts, :resource, resource)

    Enum.reduce(subjects, %{in: [], out: [], unknown: []}, fn subject, acc ->
      case status(resource, subject, predicate, opts) do
        {:in, _fact} -> %{acc | in: [subject | acc.in]}
        {:out, _fact} -> %{acc | out: [subject | acc.out]}
        {:unknown, reason} -> %{acc | unknown: [{subject, reason} | acc.unknown]}
      end
    end)
    |> Map.new(fn {partition, members} ->
      {partition, members |> Enum.reverse() |> Enum.sort()}
    end)
  end

  @doc """
  The bounded assess selection: the subjects whose facts are missing,
  stale, expired or below the grade floor — exactly the `unknown` reason
  classes that reassessment can change — optionally scored by the
  `:priority` MFA seam and capped by `:limit`.

  Returns `%{subject => reason}` pairs (insertion-ordered by descending
  priority when a seam is given; the S1-56 retrieval-scored priority
  replaces the seam's contents later — the seam is the contract, the
  retrieval is not built here).

  Nothing here judges: the caller wires the returned subjects into its
  judge actions and the resulting admissions back through
  `AshJudgments.Facts.Materialiser.materialise/2`.
  """
  @spec assess(module(), [term()], String.t(), keyword()) :: [{term(), atom()}]
  def assess(resource, subjects, predicate, opts \\ []) do
    limit = Keyword.get(opts, :limit, @assess_default_limit)
    priority = Keyword.get(opts, :priority)

    %{unknown: candidates} = tri_state(resource, subjects, predicate, opts)

    candidates
    |> maybe_prioritise(priority)
    |> Enum.take(limit)
  end

  defp maybe_prioritise(candidates, nil), do: candidates

  defp maybe_prioritise(candidates, {m, f, a}) do
    candidates
    |> Enum.map(fn {subject, reason} -> {subject, reason, apply(m, f, [subject, reason | a])} end)
    |> Enum.sort_by(&elem(&1, 2), :desc)
    |> Enum.map(&{elem(&1, 0), elem(&1, 1)})
  end

  ## Per-fact decision

  defp decide(fact, opts, current_digest) do
    min_grade = Keyword.get(opts, :min_grade, :grant)

    cond do
      not AshJudgments.Facts.grade_at_least?(fact.admission_grade, min_grade) ->
        {:unknown, :below_grade}

      stale?(fact, current_digest) ->
        # Stale facts read as unknown and are queued for reassessment
        # (S1-56 §1.4); ordering may still show them — that is the
        # explore tier's concern, not membership's.
        {:unknown, :stale}

      expired?(fact) ->
        {:unknown, :expired}

      fact.holds == true ->
        {:in, fact}

      fact.holds == false ->
        {:out, fact}

      true ->
        {:unknown, :no_fact}
    end
  end

  defp in_scope?(fact, opts) do
    scope = Keyword.get(opts, :scope)

    fact.scope == scope ||
      (is_map(scope) and is_map(fact.scope) and scope_subset?(fact.scope, scope))
  end

  # A fact holds in a NARROWER scope than the consumer asks: the asked
  # scope's keys must all agree with the fact's. A fact with no scope
  # only serves scope-less reads.
  defp scope_subset?(fact_scope, asked) do
    Enum.all?(asked, fn {k, v} ->
      Map.get(fact_scope, k) == v or Map.get(fact_scope, to_string(k)) == v
    end)
  end

  defp stale?(fact, current_digest),
    do:
      not is_nil(fact.subject_state_digest) and not is_nil(current_digest) and
        fact.subject_state_digest != current_digest

  defp expired?(fact),
    do: fact.valid_until != nil and DateTime.compare(fact.valid_until, DateTime.utc_now()) != :gt

  defp current_digest(opts, subject) do
    opts |> Keyword.get(:current_digests, %{}) |> Map.get(subject)
  end

  defp current_facts(resource, subject, predicate, opts) do
    resource
    |> Ash.Query.for_read(:for_subject, %{subject: subject, predicate: predicate})
    |> Ash.read!()
    |> Enum.filter(&in_scope?(&1, opts))
  end

  defp grade_rank({:in, fact}), do: grade_rank_of(fact.admission_grade)
  defp grade_rank({:out, fact}), do: grade_rank_of(fact.admission_grade)
  defp grade_rank({:unknown, _reason}), do: 0
  defp grade_rank_of(:person), do: 2
  defp grade_rank_of(:grant), do: 1
end
