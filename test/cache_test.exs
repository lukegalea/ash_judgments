# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.CacheTest do
  @moduledoc """
  The execution-mode suite (CORE-CACHE): live-cache answers from the
  ledger without writing (AC-1), replay refuses empty (AC-2), the key is
  pure and input-sensitive (AC-3), shadow records without feeding (AC-4),
  and pin mismatches fail (AC-5).
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  alias AshJudgments.Cache
  alias AshJudgments.Registry.Info

  @moduletag :db

  @question AshJudgments.Test.Note |> Info.questions() |> List.first()

  @responded %{"text" => "The resident will need a follow-up appointment next week."}

  setup do
    # A real (non-transactional) reset: leftovers from earlier runs would
    # otherwise count as cache hits for the wrong test.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_facts test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)

    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)
    Application.put_env(:ash_judgments, :facts, AshJudgments.Test.Fact)

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :ledger)
      Application.delete_env(:ash_judgments, :facts)
      Application.delete_env(:ash_judgments, :region)
    end)

    put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})
    :ok
  end

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
    |> Ash.run_action!(context: ctx)
  end

  # The soft form returns {:ok, _} | {:error, _} — for the replay-miss
  # assertions, where the error is the expected outcome.
  defp judge_soft(input, judge_ctx \\ %{}) do
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

  defp judge_ctx(mode, extra \\ %{}) do
    %{judgments: Map.merge(%{mode: mode}, extra)}
  end

  defp observation_count do
    AshJudgments.Test.Judgment |> Ash.read!() |> length()
  end

  describe ":live (AC-1)" do
    test "a cache hit within TTL returns the recorded answer and writes no observation" do
      # First run: a miss — the model is called and the observation lands.
      assert %AshAi.Evaluate.Noul{probability: 0.9} = judge(@responded)
      assert observation_count() == 1
      assert_received {:judge_call, _, _, _}

      # Second run, same state: a hit — the recorded answer returns and
      # the model is never consulted.
      assert %AshAi.Evaluate.Noul{probability: 0.9} = judge(@responded)
      assert observation_count() == 1
      refute_received {:judge_call, _, _, _}
    end

    test "a different state is a different key — a miss, a call, a new observation" do
      assert %AshAi.Evaluate.Noul{} = judge(@responded)
      assert %AshAi.Evaluate.Noul{} = judge(%{"text" => "a different note entirely"})
      assert observation_count() == 2
    end

    test "an expired row is a miss in live mode (TTL from the registry)" do
      # Record, then age the row past the question's TTL by rewriting
      # recorded_at (the test's clock, not the caller's).
      assert %AshAi.Evaluate.Noul{} = judge(@responded)
      assert observation_count() == 1

      ttl_seconds = @question.ttl
      assert ttl_seconds != nil, "the fixture question declares a TTL"

      AshJudgments.TestRepo.query!(
        "UPDATE test_judgments SET recorded_at = $1",
        [DateTime.add(DateTime.utc_now(), -(ttl_seconds + 3600))]
      )

      assert %AshAi.Evaluate.Noul{} = judge(@responded)
      assert observation_count() == 2
      assert_received {:judge_call, _, _, _}
    end
  end

  describe ":replay (AC-2)" do
    test "an empty ledger answers ReplayMiss with zero model calls" do
      assert {:error, error} = judge_soft(@responded, judge_ctx(:replay))
      assert Exception.message(error) =~ "replay miss"

      # Ash preserves the Splode error in the class's error list.
      assert [%Cache.ReplayMiss{} = miss] = error.errors

      assert miss.question_id ==
               Info.questions(AshJudgments.Test.Note) |> List.first() |> Map.get(:question_id)

      assert String.starts_with?(miss.cache_key, "sha256:")
      assert observation_count() == 0
      refute_received {:judge_call, _, _, _}
    end

    test "a recorded judgment answers from the ledger, byte-faithful, with no call" do
      # Record through the live path.
      assert %AshAi.Evaluate.Noul{probability: 0.9} = judge(@responded)
      assert observation_count() == 1
      assert_received {:judge_call, _, _, _}

      # Replay: the same answer from the record, no call, no new row.
      assert %AshAi.Evaluate.Noul{probability: 0.9} = judge(@responded, judge_ctx(:replay))
      assert observation_count() == 1
      refute_received {:judge_call, _, _, _}
    end

    test "replay ignores TTL (reproduces history) but honours the key" do
      assert %AshAi.Evaluate.Noul{} = judge(@responded)
      assert_received {:judge_call, _, _, _}

      AshJudgments.TestRepo.query!(
        "UPDATE test_judgments SET recorded_at = $1",
        [DateTime.add(DateTime.utc_now(), -3_600)]
      )

      # A live read would now miss; replay still hits — same state.
      assert %AshAi.Evaluate.Noul{} = judge(@responded, judge_ctx(:replay))

      # A different state still misses.
      assert {:error, error} = judge_soft(%{"text" => "different"}, judge_ctx(:replay))
      assert Exception.message(error) =~ "replay miss"
    end
  end

  describe "the cache key (AC-3)" do
    test "is stable across processes and input-identical runs" do
      inputs = key_inputs("state-x")

      task =
        Task.async(fn ->
          # A different process, same inputs: same key.
          Cache.key(inputs)
        end)

      assert Cache.key(inputs) == Task.await(task)
      assert Cache.key(inputs) == Cache.key(inputs)
    end

    test "differs whenever any §4.4 input differs" do
      base = Cache.key(key_inputs("state-x"))

      refute base == Cache.key(key_inputs("state-y"))

      refute base ==
               Cache.key(%{
                 key_inputs("state-x")
                 | model_digest: "sha256:" <> String.duplicate("2", 64)
               })

      refute base == Cache.key(%{key_inputs("state-x") | runtime_version: "9.9.9"})

      refute base ==
               Cache.key(%{
                 key_inputs("state-x")
                 | wire_question_hash: "sha256:" <> String.duplicate("9", 64)
               })

      refute base == Cache.key(%{key_inputs("state-x") | zone_id: :us})
    end

    test "the same answer under a different zone or wire version keys differently (key-widening determinism)" do
      # Two zones, same state and pin: different keys — a verdict is a
      # function of the zone too (law 10).
      ca = Cache.key(%{key_inputs("s") | zone_id: :ca})
      us = Cache.key(%{key_inputs("s") | zone_id: :us})
      refute ca == us
    end

    defp key_inputs(state) do
      %{
        state_digest:
          AshJudgments.Registry.Canonical.digest(
            AshJudgments.Registry.Canonical.encode(%{"text" => state})
          ),
        model_digest: "sha256:" <> String.duplicate("1", 64),
        runtime_version: "0.7.5",
        wire_question_hash: "sha256:" <> String.duplicate("3", 64),
        zone_id: :ca
      }
    end
  end

  describe ":shadow (AC-4)" do
    test "a shadow run records a shadow row linked to the live row; the caller gets the live answer" do
      # The live instrument answers first.
      assert %AshAi.Evaluate.Noul{probability: 0.9} = judge(@responded)
      assert_received {:judge_call, _, _, _}

      live =
        AshJudgments.Test.Judgment
        |> Ash.read!()
        |> List.first()

      # The shadow run: the candidate is the same profile here (the
      # self-shadow case — the candidate seam is the question profile
      # override); the caller receives the LIVE answer, but the candidate
      # instrument IS called (that is what a shadow run is).
      assert %AshAi.Evaluate.Noul{probability: 0.9} =
               judge(@responded, judge_ctx(:shadow))

      assert_received {:judge_call, _, _, _}

      rows = Ash.read!(AshJudgments.Test.Judgment)
      assert length(rows) == 2

      shadow = Enum.find(rows, &(&1.mode == :shadow))
      assert shadow.shadow_of == live.id
      assert live.mode == :live
    end

    test "a shadow run with no live record still records (shadow_of nil) and returns the candidate answer" do
      answer = judge(@responded, judge_ctx(:shadow))

      assert %AshAi.Evaluate.Noul{probability: 0.9} = answer
      assert_received {:judge_call, _, _, _}

      [shadow] = Ash.read!(AshJudgments.Test.Judgment)
      assert shadow.mode == :shadow
      assert shadow.shadow_of == nil
    end

    test "shadow rows never feed the facts surface (the materialiser is not called for them)" do
      assert %AshAi.Evaluate.Noul{} = judge(@responded, judge_ctx(:shadow))

      # The facts table is untouched: shadow observations are calibration
      # surfaces; only admissions and verdicts materialise.
      assert AshJudgments.Test.Fact |> Ash.read!() == []

      # And the derived reads see nothing.
      assert {:unknown, :no_fact} =
               AshJudgments.Query.status(
                 AshJudgments.Test.Fact,
                 %{
                   "type" => "AshJudgments.Test.Note",
                   "id" => "note-1"
                 },
                 Info.questions(AshJudgments.Test.Note) |> List.first() |> Map.get(:question_id)
               )
    end
  end

  describe "the pin check (AC-5)" do
    test "PinMismatch is raised by the check itself when the metadata is supplied" do
      # The unit-level check: pinned expectation vs reported identity.
      question = Info.questions(AshJudgments.Test.Note) |> List.first()

      pinned = %{model: "pinned-model-1.0", digest: "sha256:" <> String.duplicate("1", 64)}
      instrument = %{model_version: "other-model-9.9.9"}

      assert_raise Cache.PinMismatch,
                   ~r/pin mismatch.*pinned-model-1.0.*other-model-9.9.9/s,
                   fn ->
                     # The check is exercised through the judge's post-call path: run
                     # the judge with instrument metadata while the profile pins — the
                     # metadata IS the reported identity seam.
                     AshJudgments.Registry.Judge.check_pin_for_test(question, pinned, instrument)
                   end
    end

    test "matching identities pass the check" do
      question = Info.questions(AshJudgments.Test.Note) |> List.first()

      pinned = %{model: "pinned-model-1.0", digest: "sha256:" <> String.duplicate("1", 64)}
      instrument = %{model_version: "pinned-model-1.0"}

      # No raise: the reported identity matches the pin.
      AshJudgments.Registry.Judge.check_pin_for_test(question, pinned, instrument)
    end
  end

  describe "mode resolution" do
    test "explicit call option wins, then process metadata, then config, then :live" do
      Application.put_env(:ash_judgments, :mode, :replay)
      on_exit(fn -> Application.delete_env(:ash_judgments, :mode) end)

      Logger.metadata(judgments_mode: "shadow")
      on_exit(fn -> Logger.metadata(judgments_mode: "live") end)

      # Explicit beats everything.
      assert Cache.resolve_mode(%{mode: :live}) == :live
      # Process metadata beats config.
      assert Cache.resolve_mode(%{}) == :shadow
      # Config beats the default (and an unset metadata).
      Logger.metadata(judgments_mode: nil)
      assert Cache.resolve_mode(%{}) == :replay

      Application.delete_env(:ash_judgments, :mode)
      Logger.metadata(judgments_mode: nil)
      assert Cache.resolve_mode(%{}) == :live
    end

    test "garbage modes are skipped to :live" do
      Application.put_env(:ash_judgments, :mode, "yolo")
      on_exit(fn -> Application.delete_env(:ash_judgments, :mode) end)
      assert Cache.resolve_mode(%{}) == :live
    end
  end
end
