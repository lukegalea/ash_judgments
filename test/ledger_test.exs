# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.LedgerTest do
  @moduledoc """
  The judgment ledger's own suite (CORE-LEDGER): the record/replay
  contract, the failure postures, the audit events, erasure, and the
  region rule.
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  @moduletag :db

  alias AshJudgments.Ledger
  alias AshJudgments.Registry.Canonical

  setup do
    # A real (non-transactional) reset: leftovers from debug runs would
    # otherwise sit in the ledger forever.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_facts test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :region, :ca)
    on_exit(fn -> Application.delete_env(:ash_judgments, :region) end)
    :ok
  end

  @observation_id "11111111-1111-4111-8111-111111111111"

  defp observation_inputs(overrides \\ []) do
    Keyword.merge(
      [
        id: @observation_id,
        question_id: "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency",
        question_hash: "sha256:" <> String.duplicate("a", 64),
        question_version: 1,
        family: "clinic_triage",
        subject_type: "AshJudgments.Test.Appointment",
        subject_id: "appt-1",
        state_digest: Canonical.digest(Canonical.encode(%{"reason" => "synthetic"})),
        answer_kind: :choice,
        value: "urgent",
        probabilities: %{"urgent" => "0.9", "insufficient" => "0.1"},
        confidence: Decimal.new("0.9"),
        model_spec_requested: "typesafe:test-model",
        model_version: "test-model-1.0.0",
        model_digest: "sha256:" <> String.duplicate("b", 64),
        runtime_version: "0.7.5",
        profile: "test_local",
        latency_us: 1_234,
        correlation_id: nil,
        valid_until: nil
      ],
      overrides
    )
  end

  defp record!(overrides \\ []) do
    AshJudgments.Test.Judgment
    |> Ash.Changeset.for_create(:record, observation_inputs(overrides))
    |> Ash.create!()
  end

  describe "the :record create" do
    test "records the observation with pure derived fields" do
      judgment = record!()

      assert judgment.region == "ca"

      assert judgment.cache_key ==
               Ledger.cache_key(%{
                 model_version: "test-model-1.0.0",
                 question_hash: observation_inputs()[:question_hash],
                 state_digest: observation_inputs()[:state_digest]
               })

      refute judgment.record_hash == nil
      assert judgment.record_version == "0"
      assert judgment.mode == :live
      assert judgment.residency == :in_cluster
      assert %DateTime{} = judgment.recorded_at
    end

    test "derived fields are PURE: the same inputs give the same digests" do
      # The replay-safety property at unit scale (the integration proof is
      # the AshEvents replay below): record/delete/record the same inputs
      # and every derived field is identical.
      first = record!()
      hash_one = first.record_hash
      key_one = first.cache_key

      AshJudgments.TestRepo.query!("DELETE FROM test_judgments")

      second = record!()

      assert second.record_hash == hash_one
      assert second.cache_key == key_one
    end

    test "the same answer and state always produce the same cache key" do
      key =
        Ledger.cache_key(%{
          model_version: "m",
          question_hash: "sha256:" <> String.duplicate("c", 64),
          state_digest: "sha256:" <> String.duplicate("d", 64)
        })

      assert key ==
               Ledger.cache_key(%{
                 model_version: "m",
                 question_hash: "sha256:" <> String.duplicate("c", 64),
                 state_digest: "sha256:" <> String.duplicate("d", 64)
               })

      refute key ==
               Ledger.cache_key(%{
                 model_version: "m2",
                 question_hash: "sha256:" <> String.duplicate("c", 64),
                 state_digest: "sha256:" <> String.duplicate("d", 64)
               })
    end

    test "region is host config, never a caller input" do
      # The region is not even an accepted input: a caller trying to set it
      # is refused outright, and every recorded row carries the config's.
      assert_raise Ash.Error.Invalid, ~r/No such input .region./, fn ->
        record!(region: "us")
      end

      assert record!().region == "ca"
    end

    test "a record without a configured region fails (AC-7)" do
      Application.delete_env(:ash_judgments, :region)

      # The bare config validation:
      assert_raise ArgumentError, ~r/no stack region configured/, fn ->
        Ledger.region!()
      end

      # And the write path surfaces it (wrapped by Ash as Unknown):
      assert_raise Ash.Error.Unknown, ~r/no stack region configured/, fn ->
        record!()
      end
    end
  end

  describe "audit events (AC-4)" do
    test "every :record create produces an AshEvents audit event" do
      judgment = record!()

      events =
        AshJudgments.Test.EventLog
        |> Ash.read!()
        |> Enum.filter(&(&1.action == :record and &1.record_id == judgment.id))

      assert length(events) == 1
    end

    test "tombstoning produces its own audit event (AC-6)" do
      judgment = record!(state_ciphertext: "encrypted-state-bytes")

      AshJudgments.Test.Judgment
      |> Ash.get!(judgment.id)
      |> Ash.Changeset.for_update(:tombstone_state)
      |> Ash.update!()

      events =
        AshJudgments.Test.EventLog
        |> Ash.read!()
        |> Enum.filter(&(&1.action == :tombstone_state and &1.record_id == judgment.id))

      assert length(events) == 1
    end
  end

  describe "erasure (AC-6)" do
    test "tombstone_state clears the payload and keeps every digest" do
      judgment = record!(state_ciphertext: "encrypted-state-bytes")

      refute judgment.state_ciphertext == nil
      digest_before = judgment.state_digest
      hash_before = judgment.record_hash

      tombstoned =
        AshJudgments.Test.Judgment
        |> Ash.get!(judgment.id)
        |> Ash.Changeset.for_update(:tombstone_state)
        |> Ash.update!()

      assert tombstoned.state_ciphertext == nil
      assert tombstoned.state_digest == digest_before
      # record_hash excludes payload fields (§4.5): it still verifies.
      assert tombstoned.record_hash == hash_before
    end

    test "a replay-mode digest lookup still verifies after erasure" do
      judgment = record!(state_ciphertext: "encrypted-state-bytes")
      state_digest = judgment.state_digest

      AshJudgments.Test.Judgment
      |> Ash.get!(judgment.id)
      |> Ash.Changeset.for_update(:tombstone_state)
      |> Ash.update!()

      [found] =
        AshJudgments.Test.Judgment
        |> Ash.Query.for_read(:by_cache_key, %{cache_key: judgment.cache_key})
        |> Ash.read!()

      # The digest the caller holds still matches the erased row's record.
      assert found.state_digest == state_digest
    end
  end

  describe "reads" do
    test "by_cache_key finds the observation" do
      judgment = record!()

      assert [%AshJudgments.Test.Judgment{id: id}] =
               AshJudgments.Test.Judgment
               |> Ash.Query.for_read(:by_cache_key, %{cache_key: judgment.cache_key})
               |> Ash.read!()

      assert id == judgment.id
    end

    test "by_subject filters by subject and question" do
      record!()
      record!(id: "22222222-2222-4222-8222-222222222222", subject_id: "appt-2")

      assert [%AshJudgments.Test.Judgment{subject_id: "appt-1"}] =
               AshJudgments.Test.Judgment
               |> Ash.Query.for_read(:by_subject, %{
                 subject_type: "AshJudgments.Test.Appointment",
                 subject_id: "appt-1"
               })
               |> Ash.read!()

      assert [%AshJudgments.Test.Judgment{}] =
               AshJudgments.Test.Judgment
               |> Ash.Query.for_read(:by_subject, %{
                 subject_type: "AshJudgments.Test.Appointment",
                 subject_id: "appt-1",
                 question_id: "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"
               })
               |> Ash.read!()
    end
  end

  describe "the human verdict fragment" do
    test "records a verdict with the reviewer as author of record" do
      judgment = record!()

      verdict =
        AshJudgments.Test.HumanVerdict
        |> Ash.Changeset.for_create(:record, %{
          judgment_id: judgment.id,
          question_hash: judgment.question_hash,
          question_version: judgment.question_version,
          model_digest: judgment.model_digest,
          model_answer: %{
            "kind" => "choice",
            "value" => "urgent",
            "distribution" => %{"urgent" => "0.9", "insufficient" => "0.1"}
          },
          model_version: judgment.model_version,
          human_value: "routine",
          reviewer: "reviewer-1",
          reason: "synthetic reason text",
          blind?: true,
          basis: :audit_sample
        })
        |> Ash.create!()

      assert verdict.reviewer == "reviewer-1"
      assert verdict.human_value == "routine"
      assert verdict.model_answer["value"] == "urgent"
      assert verdict.blind? == true
      assert verdict.basis == :audit_sample
    end
  end

  describe "the record postures (AC-2/AC-3)" do
    defp judge_with_ledger(ledger, action, resource, input_args) do
      Application.put_env(:ash_judgments, :region, :ca)
      Application.put_env(:ash_judgments, :ledger, ledger)
      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

      resource
      |> Ash.ActionInput.for_action(action, input_args)
      |> Ash.run_action(context: %{judgments: %{req_llm: AshJudgments.Test.FakeReqLLM}})
    end

    test "record: :must fails the judge action closed when the ledger insert fails (AC-2)" do
      {:error, error} =
        judge_with_ledger(
          AshJudgments.Test.FailingLedger,
          :judge_notes_follow_up,
          AshJudgments.Test.Note,
          %{"input" => %{"text" => "synthetic"}}
        )

      # No answer left the action: the error IS the failure to record.
      # (The instrument call itself was legitimate — it happened, and its
      # result died with the failed record. The zero-call proof belongs to
      # the replay test.)
      assert Exception.message(error) =~ "forced ledger failure"
    end

    test "record: :best_effort returns the answer and emits [:ash_judgments, :record, :failed] (AC-3)" do
      test_pid = self()

      :telemetry.attach(
        "ledger-failed-test",
        [:ash_judgments, :record, :failed],
        fn event, _measurements, metadata, _ -> send(test_pid, {:telemetry, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("ledger-failed-test") end)

      {:ok, answer} =
        judge_with_ledger(
          AshJudgments.Test.FailingLedger,
          :judge_appointment_note_summary,
          AshJudgments.Test.Appointment,
          %{"input" => %{"reason" => "synthetic"}}
        )

      # The answer was earned and is returned despite the failed record.
      assert %AshAi.Evaluate.Score{} = answer

      assert_receive {:telemetry, [:ash_judgments, :record, :failed], metadata}

      assert metadata.question_id ==
               "judgment:v0:AshJudgments.Test.Appointment#judgments/appointment_note_summary"

      assert metadata.record == :best_effort
      assert metadata.error_digest =~ "sha256:"
    end
  end

  describe "AshEvents replay (AC-1)" do
    # Recording through the REAL judge path with the fake model: one live
    # call answers once, its observation lands in the ledger, and the
    # replay of that ledger's event log must rebuild the row from the
    # recorded inputs alone — zero model calls (law 2, RFC §6.1).
    defp record_through_judge do
      Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)
      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

      AshJudgments.Test.Note
      |> Ash.ActionInput.for_action(:judge_notes_follow_up, %{
        "input" => %{"text" => "synthetic replay text", "patient_id" => "P-1"}
      })
      |> Ash.run_action!(context: %{judgments: %{req_llm: AshJudgments.Test.FakeReqLLM}})

      # The one live call.
      assert_received {:judge_call, _, _, _}

      [judgment] = Ash.read!(AshJudgments.Test.Judgment)
      judgment
    end

    test "replaying the log rebuilds byte-identical rows and calls no model" do
      judgment = record_through_judge()
      snapshot = Map.from_struct(judgment)

      %{rows: events} =
        AshJudgments.TestRepo.query!("SELECT resource::text, action FROM test_event_log")

      assert events == [["Elixir.AshJudgments.Test.Judgment", "record"]]

      AshJudgments.Test.EventLog
      |> Ash.ActionInput.for_action(:replay, %{})
      |> Ash.run_action!()

      # The replay answered from the recorded inputs — no model was
      # consulted, so no second fake call arrived.
      refute_received {:judge_call, _, _, _}

      rebuilt =
        AshJudgments.Test.Judgment
        |> Ash.get!(judgment.id)
        |> Map.from_struct()

      # Byte-identical in every non-timestamp column (AC-1).
      for {key, expected} <- snapshot do
        actual = Map.get(rebuilt, key)

        assert actual == expected,
               "column #{inspect(key)} differs after replay: #{inspect(expected)} != #{inspect(actual)}"
      end
    end
  end
end
