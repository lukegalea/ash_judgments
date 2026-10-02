# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Telemetry do
  @moduledoc """
  Judgment telemetry (ticket AST-90, CORE-TELEMETRY): the event registry,
  the emission helpers, and the span conversion.

  Every event the package emits is named `[:ash_judgments | ...]` and
  carries `region` — because a total that quietly covers one region is
  the most common data error (law 10) — plus the envelope-class
  identity: which question (hash/id), which instrument (digest, runtime
  version, residency), which rung answered (`:system_one`), which mode.
  **No state, no answer text, no payload-class data ever rides in
  telemetry** — asserted by a sentinel test over captured events.

  ## The event registry

  | Event | Measurements | Metadata keys |
  |---|---|---|
  | `[:ash_judgments, :judgment, :start]` | `%{system_time}` | the judge meta (below) |
  | `[:ash_judgments, :judgment, :stop]` | `%{duration, latency_us}` | the judge meta + `cache_hit?`, `outcome` |
  | `[:ash_judgments, :judgment, :exception]` | `%{duration, latency_us}` | the judge meta + `kind` |
  | `[:ash_judgments, :cache, :hit]` | `%{latency_us}` | question id, observation id, mode, region, residency, model digest/runtime version |
  | `[:ash_judgments, :cache, :replay_miss]` | `%{}` | question id/hash/family, mode, region, residency |
  | `[:ash_judgments, :pin, :mismatch]` | `%{}` | question id/hash, expected vs reported model, region |
  | `[:ash_judgments, :shadow, :diff]` | `%{delta_p}` | question id, value_changed, shadow_of, mode, region |
  | `[:ash_judgments, :record, :failed]` | `%{}` | question id/hash/family, record posture, error digest, region |
  | `[:ash_judgments, :residency, :denied]` | `%{}` | profile, residency, family, tenant, profile_region, stack_region, region — the DISCLOSURE event: an out-of-zone or policy-refused attempt, with the mismatch recorded and the endpoint NEVER named |
  | `[:ash_judgments, :ledger, :tombstoned]` | `%{}` | judgment id, region — ADR 0024 erasure: the payload went, the digests stayed |
  | `[:ash_judgments, :facts, :materialised]` | `%{count: 1}` | predicate, verdict (the materialiser's outcome atom), grade, region |

  The judge meta (on every `:judgment` event): `family`, `question_id`,
  `question_hash`, `profile`, `residency`, `model_version`,
  `model_digest`, `region`, `tenant`, `mode`, `rung` (always
  `:system_one`).

  ## OpenTelemetry shape (chosen)

  The events above are the span boundary: `:start` carries
  `system_time`, `:stop`/`:exception` carry `duration` — the
  telemetry-to-span conventions handlers already expect. The package
  ships NO hard OTel edge: `attach_otel/1` attaches handler-side span
  emission, converting each judge event into a span with attributes
  mirroring the metadata (`span_attributes/1`), and marking every
  `sub_processor` call `ai.disclosure = true` (ADR 0026: the call's one
  ledger row is the disclosure record; this is its one span). The
  emitter is injectable — hosts pass a module/functions speaking their
  OTel SDK (e.g. an `:opentelemetry` wrapper), or accept the default,
  which requires the `:opentelemetry` application and degrades to
  `{:error, :opentelemetry_unavailable}`. Nothing about the package's
  own events changes when the attachment is absent.

  ## Metrics

  `AshJudgments.Telemetry.Metrics.definitions/0` — the
  `:telemetry_metrics` definitions (counters by family × band-ish
  outcomes × region × residency, latency distributions) for
  LiveDashboard or Prometheus.

  ReqLLM's own `[:req_llm, :request, :start|:stop]` events ride
  alongside; this package re-emits nothing for them.
  """

  @moduledoc since: "0.1.0"

  @rung :system_one

  @judge_events [[:ash_judgments, :judgment, :start], [:ash_judgments, :judgment, :stop]]
  @judge_exception_event [:ash_judgments, :judgment, :exception]

  @typedoc "The judge-call metadata every `:judgment` event carries."
  @type judge_meta :: %{
          required(:family) => atom() | String.t(),
          required(:question_id) => String.t(),
          required(:question_hash) => String.t(),
          required(:profile) => atom() | String.t() | nil,
          required(:residency) => :in_cluster | :sub_processor | nil,
          required(:model_version) => String.t() | nil,
          required(:model_digest) => String.t() | nil,
          required(:region) => atom() | nil,
          required(:tenant) => term(),
          required(:mode) => atom(),
          required(:rung) => :system_one
        }

  @doc "The package's event paths, in registry order — the contract as data."
  @spec events() :: [[atom(), ...]]
  def events do
    @judge_events ++
      [
        @judge_exception_event,
        [:ash_judgments, :cache, :hit],
        [:ash_judgments, :cache, :replay_miss],
        [:ash_judgments, :pin, :mismatch],
        [:ash_judgments, :shadow, :diff],
        [:ash_judgments, :record, :failed],
        [:ash_judgments, :residency, :denied],
        [:ash_judgments, :ledger, :tombstoned],
        [:ash_judgments, :facts, :materialised]
      ]
  end

  @doc """
  Builds the judge-call metadata: envelope-class identity only. The
  instrument half comes from the resolved key inputs and the wire's
  runtime-reported model (when captured); `residency` is the declared
  class of the question's named profile (`nil` for resolver profiles —
  the host declares residency there).
  """
  @spec judge_meta(AshJudgments.Registry.Question.t(), map(), map(), map()) :: judge_meta()
  def judge_meta(question, ctx, key_inputs, timing) do
    instrument = (ctx[:judgments] || %{})[:instrument] || %{}

    %{
      family: question.family,
      question_id: question.question_id,
      question_hash: question.question_hash,
      profile: profile_name(question.profile),
      residency: residency_for(question.profile),
      model_version: model_version(instrument, timing),
      model_digest: key_inputs[:model_digest],
      region: current_region(),
      tenant: (ctx[:judgments] || %{})[:tenant],
      mode: (ctx[:judgments] || %{})[:mode] || :live,
      rung: @rung
    }
  end

  @doc "Emits `[:ash_judgments, :judgment, :start]`."
  @spec judge_start(judge_meta()) :: :ok
  def judge_start(meta) do
    :telemetry.execute(@judge_events |> hd(), %{system_time: System.system_time()}, meta)
  end

  @doc "Emits `[:ash_judgments, :judgment, :stop]`. `outcome` carries `duration` plus the outcome keys."
  @spec judge_stop(judge_meta(), non_neg_integer(), map()) :: :ok
  def judge_stop(meta, latency_us, outcome) do
    :telemetry.execute(
      @judge_events |> List.last(),
      %{duration: Map.get(outcome, :duration, latency_us), latency_us: latency_us},
      Map.merge(meta, outcome)
    )
  end

  @doc "Emits `[:ash_judgments, :judgment, :exception]` and re-raises. `duration_us` is the full-call duration."
  @spec judge_exception(judge_meta(), term(), non_neg_integer()) :: no_return()
  def judge_exception(meta, error, duration_us) do
    :telemetry.execute(
      @judge_exception_event,
      %{duration: duration_us, latency_us: duration_us},
      Map.merge(meta, %{kind: error_kind(error)})
    )

    reraise_error(error)
  end

  ## The single-purpose events (called from their seams)

  @doc false
  def cache_hit(meta) do
    :telemetry.execute([:ash_judgments, :cache, :hit], %{latency_us: 0}, meta)
  end

  @doc false
  def replay_miss(meta) do
    :telemetry.execute([:ash_judgments, :cache, :replay_miss], %{}, meta)
  end

  @doc false
  def pin_mismatch(meta) do
    :telemetry.execute([:ash_judgments, :pin, :mismatch], %{}, meta)
  end

  @doc false
  def shadow_diff(meta, delta_p) do
    :telemetry.execute([:ash_judgments, :shadow, :diff], %{delta_p: delta_p}, meta)
  end

  @doc false
  def record_failed(meta) do
    :telemetry.execute([:ash_judgments, :record, :failed], %{}, meta)
  end

  @doc """
  The disclosure event: a residency guard refused an out-of-zone (or
  policy-refused) instrument attempt. Carries the mismatch — profile,
  its residency/region vs the stack's — and NEVER the endpoint.
  """
  @spec residency_denied(map()) :: :ok
  def residency_denied(meta) do
    :telemetry.execute([:ash_judgments, :residency, :denied], %{}, Map.put(meta, :rung, @rung))
  end

  @doc false
  def tombstoned(judgment_id) do
    :telemetry.execute([:ash_judgments, :ledger, :tombstoned], %{}, %{
      judgment_id: judgment_id,
      region: current_region()
    })
  end

  @doc false
  def materialised(meta) do
    :telemetry.execute([:ash_judgments, :facts, :materialised], %{count: 1}, meta)
  end

  ## Span conversion (the OTel shape)

  @doc """
  The span attributes for a judge event's metadata — the mapping hosts'
  OTel handlers apply. `sub_processor` calls are marked
  `ai.disclosure = true` (ADR 0026: the ledger row is the disclosure
  record; this is its span). Envelope-class keys only, by construction:
  this function passes through nothing it does not name.
  """
  @spec span_attributes(map()) :: map()
  def span_attributes(meta) when is_map(meta) do
    base =
      %{
        "ash_judgments.family" => meta[:family],
        "ash_judgments.question_id" => meta[:question_id],
        "ash_judgments.question_hash" => meta[:question_hash],
        "ash_judgments.profile" => meta[:profile],
        "ash_judgments.residency" => meta[:residency],
        "ash_judgments.model_version" => meta[:model_version],
        "ash_judgments.model_digest" => meta[:model_digest],
        "ash_judgments.region" => meta[:region],
        "ash_judgments.mode" => meta[:mode],
        "ash_judgments.rung" => meta[:rung] || @rung
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    meta
    |> span_outcome_attributes()
    |> Map.merge(base)
  end

  defp span_outcome_attributes(meta) do
    outcome =
      %{}
      |> maybe_attr("ash_judgments.cache_hit", meta[:cache_hit?])
      |> maybe_attr("ash_judgments.outcome", meta[:outcome])
      |> maybe_attr("ash_judgments.error_kind", meta[:kind])

    if meta[:residency] == :sub_processor do
      Map.put(outcome, "ai.disclosure", true)
    else
      outcome
    end
  end

  defp maybe_attr(map, _key, nil), do: map
  defp maybe_attr(map, key, value), do: Map.put(map, key, value)

  @doc """
  Attaches handler-side span emission for the judge events. `emitter`
  is `%{start_span: fun, end_span: fun, record_exception: fun}` (or a
  module implementing those); the default uses the `:opentelemetry`
  application and returns `{:error, :opentelemetry_unavailable}` when
  it is not loaded — telemetry-only operation is the degradation, never
  a raise.

  A span starts on `:judgment, :start` (keyed by self()), ends on
  `:stop` (or records the exception on `:exception`), with
  `span_attributes/1` as its attributes.
  """
  @spec attach_otel(term()) ::
          :ok | {:error, :opentelemetry_unavailable | :already_attached}
  def attach_otel(emitter \\ :default) do
    cond do
      emitter != :default ->
        do_attach(emitter)

      sdk_available?() ->
        do_attach(AshJudgments.Telemetry.OtelEmitter)

      true ->
        {:error, :opentelemetry_unavailable}
    end
  end

  defp sdk_available? do
    # The same env-sourced check the default emitter applies per call.
    sdk = Application.get_env(:ash_judgments, :otel_module, :opentelemetry)
    Code.ensure_loaded?(sdk) and function_exported?(sdk, :start_span, 3)
  end

  defp do_attach(emitter) do
    if handler_attached?() do
      {:error, :already_attached}
    else
      events = [@judge_events |> hd(), @judge_events |> List.last(), @judge_exception_event]

      :ok =
        :telemetry.attach_many(
          {__MODULE__, :otel_spans},
          events,
          &__MODULE__.otel_handler/4,
          emitter
        )
    end
  end

  defp handler_attached? do
    :telemetry.list_handlers(@judge_events |> hd())
    |> Enum.any?(&(&1.id == {__MODULE__, :otel_spans}))
  end

  @doc "Detaches the span-emission handlers (tests, host shutdown)."
  @spec detach_otel() :: :ok
  def detach_otel do
    :telemetry.detach({__MODULE__, :otel_spans})
  end

  @doc false
  def otel_handler([:ash_judgments, :judgment, :start], _measurements, meta, emitter) do
    emitter_module(emitter).start_span(span_name(meta), span_attributes(meta))
  end

  def otel_handler([:ash_judgments, :judgment, :stop], measurements, meta, emitter) do
    emitter_module(emitter).end_span(span_name(meta), measurements)
  end

  def otel_handler([:ash_judgments, :judgment, :exception], measurements, meta, emitter) do
    emitter_module(emitter).record_exception(span_name(meta), meta[:kind], measurements)
  end

  defp span_name(_meta), do: "ash_judgments.judgment"

  defp emitter_module(:default), do: AshJudgments.Telemetry.OtelEmitter
  defp emitter_module(emitter), do: emitter

  ## Internals

  defp error_kind(error) when is_exception(error),
    do: error.__struct__ |> Module.split() |> List.last()

  defp error_kind(error) when is_atom(error), do: error
  defp error_kind(_other), do: :error

  # Called only from judge_exception/3's own rescue context; re-raising
  # the same error struct preserves the failure for the caller.
  defp reraise_error(error) when is_exception(error), do: raise(error)
  defp reraise_error(error) when is_atom(error), do: raise(error)
  defp reraise_error(_other), do: raise(RuntimeError.exception(message: "judge failed"))

  defp model_version(instrument, timing) do
    # The host-declared version wins; the wire's runtime-reported model
    # (captured in production by AshJudgments.Wire.ModelCapture) fills
    # the absence — the AST-89 deferral this ticket closes.
    instrument[:model_version] || timing[:model_reported]
  end

  @doc false
  def residency_for(profile_ref) when is_atom(profile_ref) do
    case AshJudgments.Profile.fetch(profile_ref) do
      {:ok, profile} -> profile.residency
      _ -> nil
    end
  end

  def residency_for(_resolver), do: nil

  defp profile_name(name) when is_atom(name), do: name
  defp profile_name(name) when is_binary(name), do: name
  defp profile_name(_resolver), do: nil

  @doc false
  def profileref_for(name) when is_atom(name) or is_binary(name), do: name
  def profileref_for(_resolver), do: nil

  @doc false
  def current_region do
    case AshJudgments.Ledger.region() do
      {:ok, region} -> region
      _ -> nil
    end
  end
end
