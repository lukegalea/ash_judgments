# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.HumanVerdict.FromBanding do
  @moduledoc """
  A person's verdict on a review-banded judgment: the implementation of a
  host banding resource's `:record_verdict` generic action, the act the
  `AshJudgments.A2ui.Verdicts` surface offers.

  ```elixir
  action :record_verdict, :map do
    argument :record_id, :uuid, allow_nil?: false
    argument :answer, :atom, allow_nil?: false, constraints: [one_of: [:yes, :no]]
    argument :why, :string

    run {AshJudgments.HumanVerdict.FromBanding,
         verdict_resource: MyApp.SystemOne.HumanVerdict,
         judgment_resource: MyApp.SystemOne.Judgment}
  end
  ```

  The answer is `answer` (or `value`, for a host that names it so) and
  the reason is `why` (or `reason`). Declare `answer` as an `:atom` with
  `one_of: [:yes, :no]` when the questions are yes/no, so the surface
  offers a Yes/No picker, or as a `:string` when some are not.

  It writes one verdict per observation through the verdict resource's
  `:record`, as the actor and in the action's tenant, so the host's
  verdict policies decide who may record one. Each verdict carries the
  observation's answer as its `model_answer`, its question hash, version,
  digest and state reference, the basis `:review_task`, and the actor as
  `reviewer` (their `email`, else their `id`; override with `:reviewer`,
  a function of the actor). Each one is a person-made calibration label.

  **Duplicates are settled together.** Two runs over the same unchanged
  text record two observations with the same `subject_type`,
  `subject_id`, `question_hash` and `state_digest`, and both bandings
  wait for a verdict. In the same transaction, the verdict also settles
  every other banding in the `review` band with no verdict whose
  observations all share that key with this banding's own: one verdict
  per observation, so each stays a calibration sample.
  `AshJudgments.HumanVerdict.AwaitingVerdict` lists only one of them.

  It refuses, writing nothing:

  - a banding that is not in the `review` band;
  - a banding that already has a verdict for any of its observations;
  - a call with no actor: a verdict is a person's;
  - a value outside the question's answer space: yes or no for a yes/no
    observation, as `:yes`/`:no`, `"yes"`/`"no"`, `true`/`false` or
    `"true"`/`"false"` (stored as `"true"` and `"false"`), any non-empty
    value otherwise.

  The verdicts are written in one transaction when the data layer has one.
  Returns `{:ok, %{verdicts: n, bandings: m}}`: the verdicts written and
  the bandings they settled.
  """
  @moduledoc since: "0.3.3"

  use Ash.Resource.Actions.Implementation

  import Ash.Expr

  require Ash.Query

  @impl true
  def run(input, opts, context) do
    verdicts = Keyword.fetch!(opts, :verdict_resource)
    judgments = Keyword.fetch!(opts, :judgment_resource)
    reviewer = Keyword.get(opts, :reviewer, &default_reviewer/1)
    read_opts = Ash.Context.to_opts(context)

    with {:ok, banding} <- Ash.get(input.resource, input.arguments.record_id, read_opts),
         :ok <- in_review(banding),
         {:ok, observations} <- observations(judgments, banding, read_opts),
         :ok <- unverdicted(verdicts, banding, read_opts),
         {:ok, reviewer} <- reviewer_of(reviewer, context.actor),
         {:ok, _rows} <- verdict_rows(observations, input.arguments, reviewer) do
      settle(input, banding, observations, reviewer, opts, read_opts)
    end
  end

  defp in_review(%{band: :review}), do: :ok

  defp in_review(_),
    do: {:error, "This judgment is not awaiting a verdict: it is not in the review band."}

  defp observations(judgments, banding, read_opts) do
    ids = banding.observation_ids

    judgments
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(read_opts)
    |> case do
      {:ok, rows} when length(rows) == length(ids) -> {:ok, rows}
      {:ok, _} -> {:error, "The judgments behind this banding cannot all be read."}
      error -> error
    end
  end

  defp unverdicted(verdicts, banding, read_opts) do
    ids = banding.observation_ids

    verdicts
    |> Ash.Query.filter(judgment_id in ^ids)
    |> Ash.Query.limit(1)
    |> Ash.read(read_opts)
    |> case do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, "This judgment already has a verdict."}
      error -> error
    end
  end

  ## Settling the banding and its siblings, in one transaction

  # The banding's own observations, plus those of every other banding
  # awaiting a verdict whose observations all share a subject, question
  # and unchanged state with one of them: one verdict per observation.
  defp settle(input, banding, observations, reviewer, opts, read_opts) do
    verdicts = Keyword.fetch!(opts, :verdict_resource)
    judgments = Keyword.fetch!(opts, :judgment_resource)

    write = fn ->
      siblings = siblings(input.resource, verdicts, judgments, banding, observations, read_opts)

      to_verdict =
        (observations ++ Enum.flat_map(siblings, &elem(&1, 1)))
        |> Enum.uniq_by(& &1.id)

      {:ok, rows} = verdict_rows(to_verdict, input.arguments, reviewer)

      Enum.each(rows, fn row ->
        verdicts
        |> Ash.Changeset.for_create(:record, row, read_opts)
        |> Ash.create!()
      end)

      %{verdicts: length(rows), bandings: 1 + length(siblings)}
    end

    result =
      if Ash.DataLayer.data_layer_can?(verdicts, :transact) do
        Ash.DataLayer.transaction(verdicts, write)
      else
        {:ok, write.()}
      end

    case result do
      {:ok, settled} -> {:ok, settled}
      {:error, error} -> {:error, error}
    end
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Invalid] -> {:error, error}
  end

  # [{sibling banding, its observations}] for the review bandings with no
  # verdict whose every observation shares a key with the banding's own.
  defp siblings(bandings, verdicts, judgments, banding, observations, read_opts) do
    case keyed(observations) do
      [] ->
        []

      keyed ->
        same_key = judgments |> Ash.Query.filter(^any_key(keyed)) |> Ash.read!(read_opts)
        by_id = Map.new(same_key ++ observations, &{&1.id, &1})

        bandings
        |> Ash.Query.filter(^awaiting_over(Map.keys(by_id)))
        |> Ash.read!(read_opts)
        |> Enum.filter(fn sibling ->
          sibling.id != banding.id and
            Enum.all?(sibling.observation_ids, &Map.has_key?(by_id, &1)) and
            verdictless?(verdicts, sibling, read_opts)
        end)
        |> Enum.map(fn sibling -> {sibling, Enum.map(sibling.observation_ids, &by_id[&1])} end)
    end
  end

  # An observation without both subject fields has no subject to share.
  defp keyed(observations) do
    Enum.filter(observations, &(&1.subject_type != nil and &1.subject_id != nil))
  end

  defp any_key(observations) do
    observations
    |> Enum.map(fn observation ->
      expr(
        subject_type == ^observation.subject_type and subject_id == ^observation.subject_id and
          question_hash == ^observation.question_hash and
          state_digest == ^observation.state_digest
      )
    end)
    |> Enum.reduce(&expr(^&2 or ^&1))
  end

  defp awaiting_over(observation_ids) do
    over =
      observation_ids
      |> Enum.map(&expr(^&1 in observation_ids))
      |> Enum.reduce(&expr(^&2 or ^&1))

    expr(band == :review and ^over)
  end

  defp verdictless?(verdicts, banding, read_opts) do
    ids = banding.observation_ids

    verdicts
    |> Ash.Query.filter(judgment_id in ^ids)
    |> Ash.Query.limit(1)
    |> Ash.read!(read_opts)
    |> Enum.empty?()
  end

  defp verdict_rows(observations, arguments, reviewer) do
    Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, rows} ->
      case cast_value(observation.answer_kind, answer_of(arguments)) do
        {:ok, value} -> {:cont, {:ok, [row(observation, value, arguments, reviewer) | rows]}}
        error -> {:halt, error}
      end
    end)
  end

  defp row(observation, value, arguments, reviewer) do
    %{
      judgment_id: observation.id,
      question_hash: observation.question_hash,
      question_version: observation.question_version,
      model_digest: observation.model_digest,
      state_ref: observation.state_ref,
      model_answer: %{
        "kind" => to_string(observation.answer_kind),
        "value" => observation.value,
        "probabilities" => observation.probabilities
      },
      model_version: observation.model_version,
      human_value: value,
      reason: Map.get(arguments, :why) || Map.get(arguments, :reason),
      reviewer: reviewer,
      basis: :review_task
    }
  end

  # The person's answer: `answer`, or `value` for a host that names it so.
  defp answer_of(arguments) do
    case Map.fetch(arguments, :answer) do
      {:ok, answer} when not is_nil(answer) -> answer
      _ -> Map.get(arguments, :value)
    end
  end

  @yes ~w(true yes)
  @no ~w(false no)

  defp cast_value(:noul, nil), do: {:error, "A yes/no judgment takes the verdict yes or no."}

  defp cast_value(:noul, value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      v when v in @yes -> {:ok, "true"}
      v when v in @no -> {:ok, "false"}
      _ -> {:error, "A yes/no judgment takes the verdict yes or no."}
    end
  end

  defp cast_value(_kind, nil), do: {:error, "The verdict needs a value."}

  defp cast_value(_kind, value) do
    case value |> to_string() |> String.trim() do
      "" -> {:error, "The verdict needs a value."}
      v -> {:ok, v}
    end
  end

  # A verdict is somebody's: no actor, no verdict.
  defp reviewer_of(_reviewer, nil),
    do: {:error, "A verdict is recorded by a person; there is no actor."}

  defp reviewer_of(reviewer, actor) do
    case reviewer.(actor) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, "The actor has no identity to record as the reviewer."}
    end
  end

  defp default_reviewer(actor) do
    case Map.get(actor, :email) || Map.get(actor, :id) do
      nil -> nil
      id -> to_string(id)
    end
  end
end
