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
    argument :value, :string, allow_nil?: false
    argument :reason, :string

    run {AshJudgments.HumanVerdict.FromBanding,
         verdict_resource: MyApp.SystemOne.HumanVerdict,
         judgment_resource: MyApp.SystemOne.Judgment}
  end
  ```

  It writes one verdict per observation in the banding through the verdict
  resource's `:record`, as the actor and in the action's tenant, so the
  host's verdict policies decide who may record one. Each verdict carries
  the observation's answer as its `model_answer`, its question hash,
  version, digest and state reference, the basis `:review_task`, and the
  actor as `reviewer` (their `email`, else their `id`; override with
  `:reviewer`, a function of the actor).

  It refuses, writing nothing:

  - a banding that is not in the `review` band;
  - a banding that already has a verdict for any of its observations;
  - a call with no actor: a verdict is a person's;
  - a value outside the question's answer space: `"true"` or `"false"`
    for a yes/no observation (`"yes"` and `"no"` are accepted and
    stored as `"true"` and `"false"`), any non-empty value otherwise.

  The verdicts are written in one transaction when the data layer has one.
  Returns `{:ok, %{verdicts: n}}`.
  """
  @moduledoc since: "0.3.3"

  use Ash.Resource.Actions.Implementation

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
         {:ok, rows} <- verdict_rows(observations, input.arguments, reviewer) do
      record(verdicts, rows, read_opts)
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

  defp verdict_rows(observations, arguments, reviewer) do
    Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, rows} ->
      case cast_value(observation.answer_kind, arguments.value) do
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
      reason: Map.get(arguments, :reason),
      reviewer: reviewer,
      basis: :review_task
    }
  end

  @yes ~w(true yes)
  @no ~w(false no)

  defp cast_value(:noul, value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      v when v in @yes -> {:ok, "true"}
      v when v in @no -> {:ok, "false"}
      _ -> {:error, "A yes/no judgment takes the verdict yes or no."}
    end
  end

  defp cast_value(_kind, value) do
    case value |> to_string() |> String.trim() do
      "" -> {:error, "The verdict needs a value."}
      v -> {:ok, v}
    end
  end

  defp record(verdicts, rows, read_opts) do
    create = fn ->
      Enum.each(rows, fn row ->
        verdicts
        |> Ash.Changeset.for_create(:record, row, read_opts)
        |> Ash.create!()
      end)

      length(rows)
    end

    result =
      if Ash.DataLayer.data_layer_can?(verdicts, :transact) do
        Ash.DataLayer.transaction(verdicts, create)
      else
        {:ok, create.()}
      end

    case result do
      {:ok, n} -> {:ok, %{verdicts: n}}
      {:error, error} -> {:error, error}
    end
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Invalid] -> {:error, error}
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
