# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.TelemetryTest do
  @moduledoc """
  CORE-TELEMETRY: the judge telemetry contract — start/stop/exception
  with the full envelope metadata, the envelope-only invariant (no
  state or answer text in ANY event or span), the disclosure events on
  residency-guard refusals, the production model-version capture, the
  latency measurements, and the handler-side span emission.
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  alias AshJudgments.Telemetry

  # The sentinel that must NEVER appear in any event metadata or span
  # attribute (AC-2): the state carries it as document text, the answer
  # carries it as the judged value.
  @sentinel "QUINCE_MARMALADE_MANIFEST"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_facts test_bandings test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)
    Application.put_env(:ash_judgments, :facts, AshJudgments.Test.Fact)
    Application.put_env(:ash_judgments, :profiles, standard_profiles())
    put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :ledger)
      Application.delete_env(:ash_judgments, :facts)
      Application.put_env(:ash_judgments, :region, :ca)
      # RESTORE, don't delete: :profiles is stack config from
      # config/test.exs — later tests' judges resolve through it.
      Application.put_env(:ash_judgments, :profiles, standard_profiles())
      Telemetry.detach_otel()
    end)

    :ok
  end

  defp standard_profiles do
    [
      [
        name: :test_local,
        model: "test-model",
        base_url: {:system, "JUDGE_BASE_URL"},
        api_key: {:system, "JUDGE_API_KEY", "local"},
        residency: :in_cluster,
        region: :ca
      ]
    ]
  end

  ## The wire doubles: req_llm overrides are MODULES (upstream dot-calls
  ## `req_llm.evaluate/4`), never anonymous functions.

  defmodule ReportingLLM do
    @moduledoc false
    @judge_notes "judge_notes_follow_up"

    def evaluate(_model, _state, _questions, _opts) do
      {:ok, %{object: %{@judge_notes => %{"probability" => 0.9}}, model: "jev-1.13.0"}}
    end
  end

  defmodule ExplodingLLM do
    @moduledoc false
    def evaluate(_model, _state, _questions, _opts), do: raise("wire down")
  end

  ## Handlers

  defp capture_events(events_to_capture) do
    test_pid = self()

    handler_id = {__MODULE__, :capture, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events_to_capture,
        fn event, measurements, meta, ^test_pid ->
          send(test_pid, {:telemetry_event, event, measurements, meta})
        end,
        test_pid
      )

    handler_id
  end

  defp drain_events do
    Enum.reduce_while(Stream.repeatedly(fn -> receive_do() end), [], fn
      nil, acc -> {:halt, Enum.reverse(acc)}
      event, acc -> {:cont, [event | acc]}
    end)
  end

  defp receive_do do
    receive do
      {:telemetry_event, event, measurements, meta} -> {event, measurements, meta}
    after
      50 -> nil
    end
  end

  ## The judge path

  defp judge(input, judge_ctx \\ %{}) do
    ctx =
      Map.merge(
        %{
          judgments:
            Map.merge(%{req_llm: AshJudgments.Test.FakeReqLLM}, judge_ctx[:judgments] || %{})
        },
        Map.drop(judge_ctx, [:judgments])
      )

    AshJudgments.Test.Note
    |> Ash.ActionInput.for_action(:judge_notes_follow_up, %{"input" => input})
    |> Ash.run_action(context: ctx)
  end

  @judge_events [
    [:ash_judgments, :judgment, :start],
    [:ash_judgments, :judgment, :stop],
    [:ash_judgments, :judgment, :exception]
  ]

  describe "the judge start/stop events (AC-1)" do
    test "start and stop carry every listed metadata key, region non-nil" do
      handler = capture_events(@judge_events)

      assert {:ok, %AshAi.Evaluate.Noul{}} = judge(%{"text" => "synthetic note text"})

      events = drain_events()
      :telemetry.detach(handler)

      assert [{_, _, start_meta}] =
               Enum.filter(events, &(elem(&1, 0) == [:ash_judgments, :judgment, :start]))

      assert [{_, stop_measurements, stop_meta}] =
               Enum.filter(events, &(elem(&1, 0) == [:ash_judgments, :judgment, :stop]))

      # The metadata contract: question identity, instrument, context, outcome.
      for key <- ~w(family question_id question_hash profile residency model_version
                    model_digest region tenant mode rung)a do
        assert Map.has_key?(start_meta, key), "start metadata missing #{inspect(key)}"
      end

      assert start_meta.region == :ca
      assert start_meta.region == stop_meta.region
      assert start_meta.rung == :system_one
      assert start_meta.family == :clinic_notes
      assert start_meta.question_id =~ "notes_follow_up"

      # AC-1's latency requirement: the measurements carry duration and
      # latency_us, non-nil.
      assert is_number(stop_measurements.latency_us)
      assert is_number(stop_measurements.duration)
      assert stop_measurements.latency_us >= 0

      # The stop outcome: no cache hit on a first call; mode live.
      assert stop_meta.cache_hit? == false
      assert stop_meta.outcome == :live
    end

    test "a cache hit marks the stop outcome and the hit event rides along" do
      handler = capture_events(@judge_events ++ [[:ash_judgments, :cache, :hit]])

      ttl_ctx = %{judgments: %{mode: :live}}

      assert {:ok, %AshAi.Evaluate.Noul{}} = judge(%{"text" => "synthetic note text"}, ttl_ctx)
      assert {:ok, %AshAi.Evaluate.Noul{}} = judge(%{"text" => "synthetic note text"}, ttl_ctx)

      events = drain_events()
      :telemetry.detach(handler)

      hits = Enum.filter(events, fn {event, _, _} -> event == [:ash_judgments, :cache, :hit] end)
      assert length(hits) == 1

      {_event, _measurements, hit_meta} = hd(hits)
      assert hit_meta.region == :ca
      assert hit_meta.observation_id

      stops =
        events
        |> Enum.filter(fn {event, _, _} -> event == [:ash_judgments, :judgment, :stop] end)

      assert [_first, second] = stops
      assert elem(second, 2).cache_hit? == true
    end
  end

  describe "the envelope-only invariant (AC-2)" do
    test "no event metadata or span attribute carries state or answer text" do
      # Every event the package emits, captured around one judged call
      # whose state and answer both carry the sentinel.
      handler = capture_events(Telemetry.events())

      Application.put_env(:ash_judgments, :profiles, [
        [
          name: :test_local,
          model: @sentinel,
          base_url: {:system, "JUDGE_BASE_URL"},
          api_key: {:system, "JUDGE_API_KEY", "local"},
          residency: :in_cluster,
          region: :ca
        ]
      ])

      assert {:ok, %AshAi.Evaluate.Noul{}} = judge(%{"text" => "note about #{@sentinel}"})

      events = drain_events()
      :telemetry.detach(handler)

      # Restore the standard registry for later tests.
      Application.put_env(:ash_judgments, :profiles, standard_profiles())

      assert events != []

      serialized =
        Enum.map_join(events, "\n", fn {_e, m, meta} -> inspect(m) <> inspect(meta) end)

      refute serialized =~ @sentinel,
             "sentinel leaked into telemetry:\n#{serialized}"

      # And the span attributes the conversion produces for a rich meta
      # (including a hostile extra key) carry no unknown keys at all.
      attributes =
        Telemetry.span_attributes(%{
          family: :f,
          question_id: "q",
          question_hash: "h",
          state: @sentinel,
          answer_text: @sentinel
        })

      refute inspect(attributes) =~ @sentinel

      assert Map.keys(attributes) |> Enum.all?(&String.starts_with?(&1, "ash_judgments.")) or
               Map.keys(attributes) |> Enum.all?(&String.starts_with?(&1, "ai."))
    end
  end

  describe "the exception event (AC-4)" do
    test "a transport error fires :exception with the error's kind, and re-raises" do
      handler = capture_events(@judge_events)

      # The judge re-raises; Ash's action machinery wraps the exception —
      # the caller sees the error, the :exception event already fired.
      assert_raise Ash.Error.Unknown, ~r/wire down/, fn ->
        judge(%{"text" => "synthetic"}, %{judgments: %{req_llm: ExplodingLLM}})
      end

      events = drain_events()
      :telemetry.detach(handler)

      assert [{_event, measurements, meta} | _] =
               Enum.filter(events, fn {event, _, _} ->
                 event == [:ash_judgments, :judgment, :exception]
               end)

      assert meta.kind == "RuntimeError"
      assert meta.region == :ca
      assert measurements.duration >= 0
    end
  end

  describe "the disclosure events (residency guards)" do
    test "a region-mismatched instrument attempt emits residency_denied" do
      handler = capture_events([[:ash_judgments, :residency, :denied]])

      Application.put_env(:ash_judgments, :profiles, [
        [
          name: :wrong_zone,
          model: "hosted-model",
          api_key: {:system, "TYPESAFE_API_KEY"},
          residency: :sub_processor,
          region: :us
        ]
      ])

      Application.put_env(:ash_judgments, :region, :ca)

      assert {:error, %AshJudgments.Profile.RegionMismatch{}} =
               AshJudgments.Profile.model_spec(%{profile: :wrong_zone}, %{}, %{family: :f})

      events = drain_events()
      :telemetry.detach(handler)

      [{_event, _m, meta}] = events
      assert meta.refusal == :region_mismatch
      assert meta.profile == :wrong_zone
      assert meta.profile_region == :us
      assert meta.stack_region == :ca
      assert meta.region == :ca
      assert meta.rung == :system_one

      # The disclosure names no endpoint — the guard cannot even see one
      # here, and the metadata contract carries no such key.
      refute Map.has_key?(meta, :base_url)
      refute Map.has_key?(meta, :endpoint)
    end

    test "a policy-refused attempt emits residency_denied" do
      handler = capture_events([[:ash_judgments, :residency, :denied]])

      Application.put_env(:ash_judgments, :profiles, [
        [
          name: :hosted_profile,
          model: "hosted-model",
          api_key: {:system, "TYPESAFE_API_KEY"},
          residency: :sub_processor,
          region: :ca
        ]
      ])

      Application.put_env(:ash_judgments, :residency_policy, AshJudgments.Test.ResidencyPolicy)

      assert {:error, %AshJudgments.Profile.ResidencyDenied{}} =
               AshJudgments.Profile.model_spec(%{profile: :hosted_profile}, %{}, %{
                 family: :f,
                 tenant: "t1"
               })

      events = drain_events()
      :telemetry.detach(handler)

      Application.delete_env(:ash_judgments, :residency_policy)

      [{_event, _m, meta}] = events
      assert meta.refusal == :policy_denied
      assert meta.residency == :sub_processor
      assert meta.tenant == "t1"
      assert meta.region == :ca
    end
  end

  describe "the span emission (handler-side, injectable emitter)" do
    defmodule Collector do
      @moduledoc false
      def start_span(name, attributes) do
        send(self(), {:span_start, name, attributes})
        :ok
      end

      def end_span(name, _measurements), do: send(self(), {:span_end, name})
      def record_exception(name, kind, _m), do: send(self(), {:span_exception, name, kind})
    end

    test "one span per judge call; attributes mirror the metadata" do
      assert :ok = Telemetry.attach_otel(Collector)

      assert {:ok, %AshAi.Evaluate.Noul{}} = judge(%{"text" => "synthetic"})

      assert_receive {:span_start, "ash_judgments.judgment", attributes}
      assert attributes["ash_judgments.region"] == :ca
      assert attributes["ash_judgments.rung"] == :system_one
      assert attributes["ash_judgments.family"] == :clinic_notes
      refute Map.has_key?(attributes, "ash_judgments.state")

      assert_receive {:span_end, "ash_judgments.judgment"}

      Telemetry.detach_otel()
    end

    test "sub-processor calls are marked ai.disclosure=true (ADR 0026)" do
      attributes =
        Telemetry.span_attributes(%{family: :f, question_id: "q", residency: :sub_processor})

      assert attributes["ai.disclosure"] == true

      in_cluster =
        Telemetry.span_attributes(%{family: :f, question_id: "q", residency: :in_cluster})

      refute Map.has_key?(in_cluster, "ai.disclosure")
    end

    test "N calls produce N ledger rows and N spans" do
      assert :ok = Telemetry.attach_otel(Collector)

      for n <- 1..3 do
        assert {:ok, %AshAi.Evaluate.Noul{}} =
                 judge(%{"text" => "synthetic note " <> Integer.to_string(n)})
      end

      starts =
        Enum.reduce_while(1..6, 0, fn _i, acc ->
          receive do
            {:span_start, "ash_judgments.judgment", _} -> {:cont, acc + 1}
          after
            200 -> {:halt, acc}
          end
        end)

      assert starts == 3
      assert AshJudgments.Test.Judgment |> Ash.read!() |> length() == 3

      Telemetry.detach_otel()
    end

    test "an exception is recorded on the span" do
      assert :ok = Telemetry.attach_otel(Collector)

      assert_raise Ash.Error.Unknown, fn ->
        judge(%{"text" => "synthetic"}, %{judgments: %{req_llm: ExplodingLLM}})
      end

      assert_receive {:span_exception, "ash_judgments.judgment", "RuntimeError"}

      Telemetry.detach_otel()
    end

    test "without the SDK, the default emitter degrades — never raises" do
      Application.put_env(:ash_judgments, :otel_module, :no_such_otel_sdk)

      assert {:error, :opentelemetry_unavailable} = Telemetry.attach_otel()

      Application.delete_env(:ash_judgments, :otel_module)
    end
  end

  describe "the model-version capture (the AST-89 deferral)" do
    test "the runtime-reported model lands in the stop metadata and the record" do
      handler = capture_events(@judge_events)

      # The wire reported jev-1.13.0 (in production the default wrapper
      # captures this; here the seam is seeded directly).
      AshJudgments.Wire.ModelCapture.capture(%{model: "jev-1.13.0"})

      assert {:ok, %AshAi.Evaluate.Noul{}} =
               judge(%{"text" => "synthetic"}, %{judgments: %{req_llm: ReportingLLM}})

      events = drain_events()
      :telemetry.detach(handler)

      {_e, _m, stop_meta} =
        events |> Enum.find(fn {event, _, _} -> event == [:ash_judgments, :judgment, :stop] end)

      assert stop_meta.model_version == "jev-1.13.0"

      # And the recorded observation carries it as its model_version.
      [judgment] = AshJudgments.Test.Judgment |> Ash.read!()
      assert judgment.model_version == "jev-1.13.0"
    end

    test "the host-declared instrument version wins over the capture" do
      handler = capture_events(@judge_events)

      # The declared version must satisfy the pin (the pinned model is
      # "test-model"); it then wins over the wire's capture in the
      # metadata.
      assert {:ok, %AshAi.Evaluate.Noul{}} =
               judge(%{"text" => "synthetic"}, %{
                 judgments: %{
                   req_llm: ReportingLLM,
                   instrument: %{model_version: "test-model"}
                 }
               })

      events = drain_events()
      :telemetry.detach(handler)

      {_e, _m, stop_meta} =
        events |> Enum.find(fn {event, _, _} -> event == [:ash_judgments, :judgment, :stop] end)

      assert stop_meta.model_version == "test-model"
    end
  end

  describe "the remaining events" do
    test "replay_miss, tombstoned and materialised carry region" do
      handler =
        capture_events([
          [:ash_judgments, :cache, :replay_miss],
          [:ash_judgments, :ledger, :tombstoned],
          [:ash_judgments, :facts, :materialised]
        ])

      # Replay miss: judged in replay mode against an empty ledger.
      assert {:error, %{errors: [%AshJudgments.Cache.ReplayMiss{}]}} =
               judge(%{"text" => "synthetic"}, %{judgments: %{mode: :replay}})

      # Tombstone: the recorded row's payload goes.
      row =
        AshJudgments.Test.Judgment
        |> Ash.Changeset.for_create(:record, observation_inputs())
        |> Ash.create!()

      row |> Ash.Changeset.for_action(:tombstone_state, %{}) |> Ash.update!()

      # Materialise: one admitted fact.
      AshJudgments.Facts.Materialiser.materialise(%{
        result: :admitted,
        subject: %{"type" => "AshJudgments.Test.Appointment", "id" => "appt-1"},
        predicate: "judgment:v0:X#judgments/y",
        value: %{"option" => "urgent"},
        holds: true,
        grade: :grant,
        admission_id: Ash.UUID.generate()
      })

      events = drain_events()
      :telemetry.detach(handler)

      by_event = Map.new(events, fn {event, m, meta} -> {List.last(event), {m, meta}} end)

      {miss_m, miss_meta} = Map.fetch!(by_event, :replay_miss)
      assert miss_meta.region == :ca
      assert miss_meta.mode == :replay

      {_, tomb_meta} = Map.fetch!(by_event, :tombstoned)
      assert tomb_meta.region == :ca
      assert tomb_meta.judgment_id

      {mat_m, mat_meta} = Map.fetch!(by_event, :materialised)
      assert mat_m.count == 1
      assert mat_meta.verdict == :materialised
      assert mat_meta.region == :ca
    end
  end

  defp observation_inputs do
    [
      question_id: "judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up",
      question_hash: "sha256:" <> String.duplicate("a", 64),
      question_version: 1,
      family: "clinic_notes",
      subject_type: "AshJudgments.Test.Note",
      subject_id: "note-1",
      state_digest: AshJudgments.Registry.Canonical.digest("x"),
      answer_kind: :noul,
      value: nil,
      probabilities: %{"true" => "0.9", "false" => "0.1"},
      confidence: Decimal.new("0.9"),
      model_spec_requested: "typesafe:test-model",
      model_version: "test-model-1.0.0",
      model_digest: "sha256:" <> String.duplicate("b", 64),
      runtime_version: "0.7.5",
      profile: "test_local",
      latency_us: 1_234,
      mode: :live
    ]
  end

  describe "the metrics definitions" do
    test "the definitions build when telemetry_metrics is available" do
      case Telemetry.Metrics.definitions() do
        {:error, :telemetry_metrics_unavailable} ->
          flunk("telemetry_metrics is an optional test dep — expected available")

        definitions ->
          assert definitions != []
          names = Enum.map(definitions, & &1.name)

          assert [:ash_judgments, :judgment, :stop, :latency_us] in names
          assert [:ash_judgments, :judgment, :stop, :count] in names
          assert [:ash_judgments, :residency, :denied, :count] in names

          # Every distribution rides the latency measurement.
          latency =
            Enum.find(
              definitions,
              &(&1.name == [:ash_judgments, :judgment, :stop, :latency_us])
            )

          assert latency.event_name == [:ash_judgments, :judgment, :stop]
      end
    end
  end
end
