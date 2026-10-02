# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Judge do
  @moduledoc """
  The implementation behind every generated `judge_<name>` action.

  It is plumbing, not policy: the question's declaration (profile, state
  projection, answer type) is resolved and handed to upstream
  `AshAi.Actions.Evaluate`, which owns the call and the casting. What this
  module adds:

  - the **profile** is resolved through `AshJudgments.Profile.model_spec/3`
    in the action path — the tenant opt-out, the region guard and the pin
    run here, next to the client (never in a policy check, law 3);
  - the **state** is the projection's output (`project(input, context)
    :: map`), never the raw action input — the PII-minimisation seam; with
    no projection, upstream's default state (the arguments) applies;
  - a **`req_llm` override** is honoured from
    `context[:judgments][:req_llm]` — how the contract tests capture the
    wire without a model;
  - the answer is handed to the configured **recorder**
    (`config :ash_judgments, :recorder`, a module implementing
    `record/4`). Until CORE-LEDGER lands the default is a no-op.
  """

  @moduledoc since: "0.1.0"

  use Ash.Resource.Actions.Implementation

  alias AshJudgments.Profile
  alias Spark.Dsl.Extension

  @impl true
  def run(input, opts, context) do
    question =
      Extension.get_persisted(input.resource, :questions)
      |> Enum.find(&(&1.name == Keyword.fetch!(opts, :question)))

    # The action context as a plain map (`input.context`) — the
    # Implementation.Context struct has no Access behaviour.
    ctx = input.context

    matrix? = Keyword.get(opts, :matrix?, false)

    evaluate_opts =
      if matrix? do
        [state: projection_fn(question), questions: matrix_questions(input)]
      else
        [state: projection_fn(question)]
      end

    with {:ok, model_spec} <- resolve_model(question, input, ctx) do
      evaluate_opts =
        evaluate_opts
        |> Keyword.put(:model, model_spec)
        |> Keyword.put(:req_llm, req_llm_override(ctx))

      with {:ok, answer} <- AshAi.Actions.Evaluate.run(input, evaluate_opts, context) do
        record(question, answer, input, context)
        {:ok, answer}
      end
    end
  end

  defp resolve_model(question, input, context) do
    case question.profile do
      resolver when is_function(resolver, 2) ->
        case resolver.(input, context) do
          spec when is_map(spec) or is_binary(spec) -> {:ok, spec}
          {:ok, spec} -> {:ok, spec}
          {:error, exception} -> {:error, exception}
        end

      name when is_atom(name) ->
        Profile.model_spec(%{profile: name, family: question.family}, input, context)
    end
  end

  # `nil` state lets upstream build its default (the action arguments); a
  # projection replaces it wholesale — the model never sees the raw input.
  defp projection_fn(%{state_projection: nil}), do: nil

  defp projection_fn(%{state_projection: projection}) when is_function(projection, 2),
    do: projection

  defp projection_fn(%{state_projection: {m, f, a}}), do: &apply(m, f, [&1, &2 | a])

  defp projection_fn(%{state_projection: m}) when is_atom(m), do: &m.project(&1, &2)

  defp matrix_questions(input) do
    input.arguments.questions
  end

  defp req_llm_override(context) do
    get_in(context || %{}, [:judgments, :req_llm])
  end

  defp record(question, answer, input, context) do
    case Application.get_env(:ash_judgments, :recorder) do
      nil -> :ok
      recorder -> recorder.record(question, answer, input, context)
    end
  end
end
