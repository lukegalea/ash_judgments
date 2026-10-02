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
    run here, next to the client, never inside a policy check (law 3);
  - the **state** is the projection's output (`project(input, context)
    :: map`), never the raw action input — the PII-minimisation seam.
    Without a projection, upstream's default applies (the action
    arguments);
  - a **`req_llm` override** is honoured from
    `context[:judgments][:req_llm]` — how the contract tests capture the
    wire without a model;
  - the answer is **recorded** by `AshJudgments.Ledger.Record` against the
    host ledger (config `:ash_judgments, :ledger`) — the instrument was
    called before any record happens, and the record create accepts the
    answer as input (law 2). The question's `record:` option decides the
    failure posture: `:must` fails the action closed; `:best_effort`
    logs, emits telemetry, and returns the answer.
  """

  @moduledoc since: "0.1.0"

  use Ash.Resource.Actions.Implementation

  alias AshJudgments.Ledger
  alias AshJudgments.Profile

  @impl true
  def run(input, opts, context) do
    # The action context as a plain map (`input.context`) — the
    # Implementation.Context struct has no Access behaviour.
    ctx = input.context

    question =
      AshJudgments.Registry.Info.questions(input.resource)
      |> Enum.find(&(&1.name == Keyword.fetch!(opts, :question)))

    matrix? = Keyword.get(opts, :matrix?, false)

    state = state_for(question, input)

    evaluate_opts =
      if matrix? do
        [state: state, questions: matrix_questions(input)]
      else
        [state: state] |> maybe_put_question_spec(question)
      end

    with {:ok, model_spec} <- resolve_model(question, input, ctx) do
      evaluate_opts =
        evaluate_opts
        |> Keyword.put(:model, model_spec)
        |> Keyword.put(:req_llm, req_llm_override(ctx))

      {latency_us, evaluate_result} =
        :timer.tc(fn -> AshAi.Actions.Evaluate.run(input, evaluate_opts, context) end)

      with {:ok, answer} <- evaluate_result,
           :ok <-
             record(question, answer, input, ctx, %{
               state: state,
               latency_us: latency_us,
               model_spec: model_spec
             }) do
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

  # The state VALUE the judge sends — the projection's output when there
  # is one, upstream's default (the arguments, string-keyed) otherwise.
  # Resolved HERE so the ledger can digest exactly what went over the
  # wire: recording a digest of something other than what was sent would
  # be a rumour with a receipt.
  defp state_for(%{state_projection: nil}, input) do
    Map.new(input.arguments, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp state_for(%{state_projection: projection}, input) when is_function(projection, 2),
    do: projection.(input, input.context)

  defp state_for(%{state_projection: {m, f, a}}, input),
    do: apply(m, f, [input, input.context | a])

  defp state_for(%{state_projection: m}, input) when is_atom(m),
    do: m.project(input, input.context)

  defp matrix_questions(input) do
    input.arguments.questions
  end

  # The declared question rides the `questions` option: its wording as the
  # instructions and its criteria (Choice option descriptions, Score
  # levels, Noul true/false descriptions) as the criteria — the sanctioned
  # per-question carrier upstream documents for exactly this. Levels and
  # option descriptions are per-question data; they do not belong on the
  # action's return constraints.
  defp maybe_put_question_spec(evaluate_opts, question) do
    criteria = question_criteria(question)

    question_spec =
      %{instructions: question_description(question)}
      |> then(&if criteria, do: Map.put(&1, :criteria, criteria), else: &1)

    Keyword.put(evaluate_opts, :questions, question_spec)
  end

  defp question_criteria(%{criteria: criteria}) when not is_nil(criteria), do: criteria

  defp question_criteria(%{type: AshAi.Evaluate.Score, constraints: constraints}) do
    constraints[:levels]
  end

  defp question_criteria(_question), do: nil

  defp question_description(%{instructions: instructions}) when is_binary(instructions),
    do: instructions

  defp question_description(question), do: question.description

  defp req_llm_override(context) do
    get_in(context || %{}, [:judgments, :req_llm])
  end

  # The record posture (law 2 + ADR 0040): compliance families fail
  # closed — a failed record means no answer leaves this action — while
  # tooling families get their answer and a `[:ash_judgments, :record,
  # :failed]` telemetry event. Either way the instrument is never re-run.
  defp record(question, answer, input, ctx, timing) do
    # One observation per answer: a matrix reply is one answer per runtime
    # question (RFC §5.1), sharing the request's state and latency.
    results =
      answer
      |> List.wrap()
      |> Enum.map(&Ledger.Record.record(question, &1, ctx, timing, input.context))

    errors = Enum.filter(results, &match?({:error, _}, &1))

    # The recorder already logged and emitted [:ash_judgments, :record,
    # :failed] per failure. Compliance families fail closed — no answer
    # leaves this action; tooling families keep their answers.
    case errors do
      [] -> :ok
      [first | _] when question.record == :must -> {:error, elem(first, 1)}
      _ -> :ok
    end
  end
end
