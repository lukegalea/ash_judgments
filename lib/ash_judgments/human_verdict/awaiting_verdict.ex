# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.HumanVerdict.AwaitingVerdict do
  @moduledoc """
  The filter of a banding resource's `:awaiting_verdict` read, as a
  preparation: bandings in the `review` band with no verdict for any of
  their observations, **one per subject, question and unchanged state**.

  ```elixir
  read :awaiting_verdict do
    prepare {AshJudgments.HumanVerdict.AwaitingVerdict,
             verdict_resource: MyApp.SystemOne.HumanVerdict,
             judgment_resource: MyApp.SystemOne.Judgment}
  end
  ```

  Two runs over the same unchanged text record two observations with the
  same `subject_type`, `subject_id`, `question_hash` and `state_digest`
  (or band the same observation twice), and each run's banding waits for
  a verdict. Only the earliest of them is listed: a banding is left out
  when another banding awaiting a verdict holds an observation with the
  same key (or the same observation) and was banded earlier (ties broken
  by id). `AshJudgments.HumanVerdict.FromBanding` settles the ones left
  out with the same verdict, so none of them is lost.

  It is a filter, so pagination, sorting and counts stay correct, and it
  is plain Ash expressions (`exists/2` over the resources named), so it
  needs no data-layer SQL. An observation without a `subject_id` matches
  only itself.
  """
  @moduledoc since: "0.3.3"

  use Ash.Resource.Preparation

  import Ash.Expr

  require Ash.Query

  @impl true
  def init(opts) do
    if is_atom(opts[:verdict_resource]) and opts[:verdict_resource] != nil and
         is_atom(opts[:judgment_resource]) and opts[:judgment_resource] != nil do
      {:ok, opts}
    else
      {:error, "AwaitingVerdict needs the :verdict_resource and :judgment_resource options"}
    end
  end

  @impl true
  def prepare(query, opts, _context) do
    Ash.Query.filter(
      query,
      ^filter(query.resource, opts[:verdict_resource], opts[:judgment_resource])
    )
  end

  @doc """
  The filter as an expression over `bandings`, for a host that composes
  its own read.
  """
  @spec filter(module(), module(), module()) :: Ash.Expr.t()
  def filter(bandings, verdicts, judgments) do
    expr(
      band == :review and not (^verdicted(verdicts)) and
        not (^earlier_sibling(bandings, verdicts, judgments))
    )
  end

  # A verdict on any of the banding's observations (parent: the banding).
  defp verdicted(verdicts) do
    unrelated_exists(verdicts, expr(judgment_id in parent(observation_ids)))
  end

  # One of the banding's observations (J1) has an observation with its key
  # (J2, possibly itself) in another banding awaiting a verdict that was
  # banded earlier. parent() is the next resource out: J2 -> J1 -> banding.
  defp earlier_sibling(bandings, verdicts, judgments) do
    earlier =
      unrelated_exists(
        bandings,
        expr(
          parent(id) in observation_ids and band == :review and ^banded_before_outer() and
            not (^verdicted(verdicts))
        )
      )

    same_key = unrelated_exists(judgments, expr(^same_key_as_parent() and ^earlier))

    unrelated_exists(judgments, expr(id in parent(observation_ids) and ^same_key))
  end

  # Inside `earlier`, three resources out is the banding being listed.
  defp banded_before_outer do
    expr(
      id != parent(parent(parent(id))) and
        (banded_at < parent(parent(parent(banded_at))) or
           (banded_at == parent(parent(parent(banded_at))) and id < parent(parent(parent(id)))))
    )
  end

  # The same observation, or one over the same subject, question and state.
  defp same_key_as_parent do
    expr(
      id == parent(id) or
        (subject_type == parent(subject_type) and subject_id == parent(subject_id) and
           question_hash == parent(question_hash) and state_digest == parent(state_digest))
    )
  end

  defp unrelated_exists(resource, expression) do
    %Ash.Query.Exists{
      path: [],
      resource: resource,
      expr: expression,
      at_path: [],
      related?: false
    }
  end
end
