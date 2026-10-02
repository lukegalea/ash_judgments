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
    logs, emits telemetry, and returns the answer;
  - **execution modes** (AST-89) resolve per call, per process, per
    config (see `AshJudgments.Cache.resolve_mode/1`): `:live` consults
    the ledger's cache before calling and answers from the record on a
    hit (no observation written); `:replay` answers strictly from the
    ledger and raises `%AshJudgments.Cache.ReplayMiss{}` on a miss;
    `:shadow` calls the candidate and records a `mode: :shadow` row with
    `shadow_of`, emitting the diff — the caller receives the live answer
    when a live record exists.
  """

  @moduledoc since: "0.1.0"

  require Logger

  use Ash.Resource.Actions.Implementation

  alias AshJudgments.Cache
  alias AshJudgments.Ledger
  alias AshJudgments.Profile
  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Registry.Info

  @impl true
  def run(input, opts, context) do
    # The action context as a plain map (`input.context`) — the
    # Implementation.Context struct has no Access behaviour.
    ctx = input.context

    case judge_and_record(question_for(input.resource, opts), input, ctx, context, opts) do
      {:ok, answer, _judgment_ids} -> {:ok, answer}
      {:error, error, _partial} -> {:error, error}
    end
  end

  @doc """
  Judges AND records, returning both the typed answer and the ids of the
  observations written for this call (one per answer; a cache hit carries
  the EXISTING observation's id — the caller references it, S1-24 §6.3).
  The signals actions are built on this: the judgment id is a BPMN
  token's join back to the full ledger row. Replay misses raise
  `AshJudgments.Cache.ReplayMiss`.
  """
  def judge_and_record(question, input, ctx, context, opts) do
    matrix? = Keyword.get(opts, :matrix?, false)
    mode = Cache.resolve_mode(ctx[:judgments] || %{})
    state = state_for(question, input)
    state_digest = Canonical.digest(Canonical.encode(state))

    wire_question = wire_question(question)
    wire_question_hash = Canonical.digest(Canonical.encode(wire_question))

    pinned = pinned_expectation(question)
    instrument = (ctx[:judgments] || %{})[:instrument] || %{}

    key_inputs = %{
      state_digest: state_digest,
      model_digest: instrument[:model_digest] || pinned[:digest],
      runtime_version: instrument[:runtime_version],
      wire_question_hash: wire_question_hash,
      zone_id: region()
    }

    call = %{
      question: question,
      input: input,
      ctx: ctx,
      context: context,
      key_inputs: key_inputs,
      state: state,
      pinned: pinned,
      instrument: instrument,
      matrix?: matrix?
    }

    dispatch_mode(mode, call, wire_question_hash)
  end

  # Each mode returns the same shape: `{:ok, answer, judgment_ids}` or
  # `{:error, error, partial}` — the error path never carries ids, because
  # nothing was recorded for the caller to reference.
  defp dispatch_mode(:replay, call, _hash) do
    case replay(call) do
      {:ok, answer, ids} -> {:ok, answer, ids}
      {:error, miss} -> {:error, miss, []}
    end
  end

  defp dispatch_mode(:shadow, call, hash) do
    {:ok, answer, ids} = shadow(call, hash)
    {:ok, answer, ids}
  end

  defp dispatch_mode(_mode, call, hash) do
    case live(call, hash) do
      {:ok, answer, ids} -> {:ok, answer, ids}
      {:error, error} -> {:error, error, []}
    end
  end

  defp question_for(resource, opts) do
    Info.questions(resource)
    |> Enum.find(&(&1.name == Keyword.fetch!(opts, :question)))
  end

  ## :live — consult the ledger, call on a miss

  defp live(
         %{question: question, input: input, ctx: ctx, key_inputs: key_inputs} = call,
         wire_question_hash
       ) do
    ledger = ledger_resource()

    with {:ok, model_spec} <- resolve_model(question, input, ctx) do
      case ledger && Cache.lookup_live(ledger, Ledger.cache_key(key_inputs), question.ttl) do
        nil ->
          miss(Map.put(call, :model_spec, model_spec), wire_question_hash)

        record ->
          {:ok, answer} = Cache.rebuild_answer(record, question)

          :telemetry.execute(
            [:ash_judgments, :cache, :hit],
            %{latency_us: 0},
            %{
              question_id: question.question_id,
              observation_id: record.id,
              mode: :live
            }
          )

          # A cache hit writes no observation: the caller references the
          # existing one (§6.3).
          {:ok, answer, [record.id]}
      end
    end
  end

  defp miss(
         %{
           question: question,
           input: input,
           ctx: ctx,
           context: context,
           key_inputs: key_inputs,
           state: state,
           pinned: pinned,
           instrument: instrument
         } =
           call,
         wire_question_hash
       ) do
    model_spec = call.model_spec
    matrix? = call.matrix?

    evaluate_opts =
      if matrix? do
        [state: state, questions: matrix_questions(input)]
      else
        [state: state] |> maybe_put_question_spec(question)
      end
      |> Keyword.put(:model, model_spec)
      |> maybe_put_req_llm(req_llm_override(ctx))

    {latency_us, evaluate_result} =
      :timer.tc(fn -> AshAi.Actions.Evaluate.run(input, evaluate_opts, context) end)

    check_pin!(question, pinned, instrument)

    with {:ok, answer} <- evaluate_result,
         {:ok, judgment_ids} <-
           record(
             question,
             answer,
             input,
             ctx,
             %{
               state: state,
               latency_us: latency_us,
               model_spec: model_spec,
               wire_question_hash: wire_question_hash,
               mode: :live,
               key_inputs: key_inputs
             }
           ) do
      {:ok, answer, judgment_ids}
    end
  end

  ## :replay — the ledger only

  defp replay(%{question: question, key_inputs: key_inputs}) do
    ledger = ledger_resource()

    record =
      case ledger && Cache.lookup_replay(ledger, Ledger.cache_key(key_inputs)) do
        {:ok, record} -> record
        _ -> nil
      end

    case record do
      nil ->
        {:error,
         Cache.ReplayMiss.exception(
           cache_key: Ledger.cache_key(key_inputs),
           question_id: question.question_id
         )}

      record ->
        {:ok, answer} = Cache.rebuild_answer(record, question)
        {:ok, answer, []}
    end
  end

  ## :shadow — the candidate runs; the caller receives the live answer

  defp shadow(
         %{question: question, input: input, ctx: ctx, key_inputs: key_inputs, state: state} =
           call,
         wire_question_hash
       ) do
    ledger = ledger_resource()
    live_record = ledger && Cache.lookup_live(ledger, Ledger.cache_key(key_inputs), question.ttl)

    candidate_question = candidate_question(question, ctx)
    candidate_ctx = %{ctx | judgments: Map.put(ctx[:judgments] || %{}, :mode, :live)}

    with {:ok, model_spec, shadow_answer, latency_us} <-
           candidate_run(candidate_question, input, candidate_ctx, call, state) do
      shadow_of = if live_record, do: live_record.id, else: nil

      record_shadow(candidate_question, shadow_answer, input, ctx, %{
        state: state,
        latency_us: latency_us,
        model_spec: model_spec,
        wire_question_hash: wire_question_hash,
        shadow_of: shadow_of
      })

      emit_diff(live_record, shadow_answer, question)

      # The caller receives the live answer when one exists — the
      # candidate's answer lives only in the shadow row.
      cond do
        live_record ->
          {:ok, live_answer} = Cache.rebuild_answer(live_record, question)
          {:ok, live_answer, []}

        is_struct(shadow_answer) ->
          {:ok, shadow_answer, []}
      end
    end
  end

  # The candidate call for a shadow run: resolve the candidate's spec,
  # run upstream through the host's judge context, and time it.
  # Returns {:ok, model_spec, shadow_answer, latency_us}.
  defp candidate_run(candidate_question, input, candidate_ctx, call, state) do
    evaluate_opts_base =
      if call.matrix? do
        [state: state, questions: matrix_questions(input)]
      else
        [state: state] |> maybe_put_question_spec(candidate_question)
      end

    with {:ok, model_spec} <- resolve_model(candidate_question, input, candidate_ctx) do
      evaluate_opts =
        evaluate_opts_base
        |> Keyword.put(:model, model_spec)
        |> maybe_put_req_llm(req_llm_override(candidate_ctx))

      {latency_us, evaluate_result} =
        :timer.tc(fn -> AshAi.Actions.Evaluate.run(input, evaluate_opts, call.context) end)

      case evaluate_result do
        {:ok, shadow_answer} -> {:ok, model_spec, shadow_answer, latency_us}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp candidate_question(question, ctx) do
    case (ctx[:judgments] || %{})[:candidate_profile] do
      nil -> question
      name when is_atom(name) -> %{question | profile: name}
      resolver when is_function(resolver, 2) -> %{question | profile: resolver}
      _ -> question
    end
  end

  defp record_shadow(question, answer, input, ctx, timing) do
    case Ledger.Record.record(
           question,
           answer,
           ctx,
           Map.put(timing, :mode, :shadow),
           input.context
         ) do
      {:ok, judgment} -> judgment
      {:error, error} -> Logger.warning("shadow record failed: #{Exception.message(error)}")
    end
  end

  defp emit_diff(live_record, shadow_answer, question) do
    live_answer =
      if live_record do
        {:ok, answer} = Cache.rebuild_answer(live_record, question)
        answer
      end

    diff = Cache.diff(live_answer, shadow_answer)

    :telemetry.execute(
      [:ash_judgments, :shadow, :diff],
      %{delta_p: diff.delta_p},
      %{
        question_id: question.question_id,
        value_changed: diff.value_changed,
        shadow_of: live_record && live_record.id
      }
    )
  end

  ## Shared resolution

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

  # An explicit nil would shadow upstream's default client (`Keyword.get(opts,
  # :req_llm, ReqLLM)` treats a present-but-nil key as the value) — a host
  # running without a judgments context must get the real client, not
  # `nil.evaluate/4`.
  defp maybe_put_req_llm(opts, nil), do: opts
  defp maybe_put_req_llm(opts, req_llm), do: Keyword.put(opts, :req_llm, req_llm)

  # The wire question: the exact object sent for this question, via the
  # answer type's own to_question/3 (§3.3 — before the provider's
  # normalisation). The hash feeds the §4.4 cache key and the record.
  defp wire_question(question) do
    criteria = question_criteria(question)
    instructions = question_description(question)

    case question.type.to_question(instructions, criteria, question.constraints) do
      {:ok, wire} -> wire
      _ -> %{instructions: instructions, criteria: criteria}
    end
  end

  defp pinned_expectation(question) do
    case question.profile do
      name when is_atom(name) ->
        case Profile.fetch(name) do
          {:ok, profile} ->
            %{
              model: profile.model,
              digest: resolve_digest(profile.digest)
            }

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp resolve_digest({:system, var}), do: System.get_env(var)
  defp resolve_digest(digest) when is_binary(digest), do: digest
  defp resolve_digest(_), do: nil

  # AC-5: with pin: :required, a runtime-reported model that differs from
  # the pinned expectation fails the call. The reported identity arrives
  # through the context's instrument metadata (the capture seam); absent
  # metadata, there is nothing to compare and the pin rides the profile
  # resolution + digest as today.
  @doc false
  # The post-call pin check, exposed for tests (AC-5's unit form).
  def check_pin_for_test(question, pinned, instrument),
    do: check_pin!(question, pinned, instrument)

  defp check_pin!(question, pinned, instrument) do
    if question.pin == :required do
      reported = instrument[:model_version]

      expected = pinned[:model]

      if reported != nil and expected != nil and reported != expected do
        raise Cache.PinMismatch,
          expected: expected,
          reported: reported,
          question_id: question.question_id
      end
    end

    :ok
  end

  defp ledger_resource do
    Application.get_env(:ash_judgments, :ledger)
  end

  defp region do
    case Ledger.region() do
      {:ok, region} -> region
      {:error, :missing_region} -> nil
    end
  end

  # The record posture (law 2 + ADR 0040): compliance families fail
  # closed — a failed record means no answer leaves this action — while
  # tooling families get their answer and a `[:ash_judgments, :record,
  # :failed]` telemetry event. Either way the instrument is never re-run.
  defp record(question, answer, input, ctx, timing) do
    # The resolved mode and key ride to the recorder: the observation must
    # carry the mode it was called under and the key the lookup used.
    # One observation per answer: a matrix reply is one answer per runtime
    # question (RFC §5.1), sharing the request's state, latency and key.
    timing = Map.put_new(timing, :mode, :live)

    results =
      answer
      |> List.wrap()
      |> Enum.map(&Ledger.Record.record(question, &1, ctx, timing, input.context))

    errors = Enum.filter(results, &match?({:error, _}, &1))
    ids = for {:ok, judgment} <- results, do: judgment.id

    case errors do
      [] -> {:ok, ids}
      [first | _] when question.record == :must -> {:error, elem(first, 1)}
      # A best-effort failure is logged and emitted; the ids that DID land
      # still come back (partial recording is a fact about the world).
      _ -> {:ok, ids}
    end
  end
end
