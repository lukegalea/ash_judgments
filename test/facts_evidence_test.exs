# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsEvidenceTest do
  @moduledoc """
  Phase 4 C1 (the facts temporal-swap design note §3): the materialiser's
  opt-in evidence assertion. A decision carrying an evidence reference is
  asserted caller-side, PRE-transaction — the observation's recorded
  input hash (its `state_digest`, the §4.4 cache key's `input_hash`) must
  equal the decision's `subject_state_digest` — and a mismatch raises
  `AshJudgments.Facts.Errors.EvidenceMismatch` before anything is
  written.

    (a) a matching reference passes silently (the ordinary verdict);
    (b) a mismatch raises the named error and nothing is written;
    (c) the assertion holds identically under materialise(clear+replay);
    (d) a nil-or-absent reference never reads the observation ledger —
        the provable-only path is unchanged.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Test.Fact
  alias AshJudgments.Test.Judgment

  @subject %{"type" => "AshJudgments.Test.Note", "id" => "evidence-note-1"}
  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"

  # The observation's recorded input hash, and the matching decision
  # digest the tests cite.
  defp input_hash, do: "sha256:" <> String.duplicate("7", 64)
  defp other_digest, do: "sha256:" <> String.duplicate("9", 64)

  setup do
    # A real (non-transactional) reset, mirroring facts_test.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")
    AshJudgments.TestRepo.query!("DELETE FROM test_judgments")

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)

    Application.put_env(:ash_judgments, :facts, Fact)
    Application.put_env(:ash_judgments, :ledger, Judgment)
    Application.put_env(:ash_judgments, :region, :ca)

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :facts)
      Application.delete_env(:ash_judgments, :ledger)
      Application.delete_env(:ash_judgments, :region)
    end)

    :ok
  end

  # --- (a) match passes silently --------------------------------------------------

  test "a matching reference passes silently: by id, by preloaded struct, and on the verdict path" do
    observation = record_observation!()

    assert {:ok, :materialised} =
             Materialiser.materialise(decision(evidence_observation_id: observation.id))

    assert current().subject_state_digest == input_hash()

    # The preloaded-struct form reaches the ordinary materialisation
    # logic untouched: the identical decision is idempotent (:unchanged),
    # which proves the struct path asserts and passes silently.
    assert {:ok, :unchanged} =
             Materialiser.materialise(decision(evidence_observation: observation))

    # The verdict path asserts the same way (§3: both entry points).
    assert {:ok, :materialised} =
             Materialiser.materialise_verdict(%{
               subject: @subject,
               predicate: @predicate,
               value: "routine",
               holds: false,
               admission_id: Ash.UUID.generate(),
               subject_state_digest: input_hash(),
               evidence_observation_id: observation.id
             })

    assert current().admission_grade == :person
  end

  # --- (b) mismatch raises the named error; nothing written -----------------------

  test "a mismatch raises EvidenceMismatch and writes nothing" do
    observation = record_observation!()

    error =
      assert_raise AshJudgments.Facts.Errors.EvidenceMismatch, fn ->
        Materialiser.materialise(
          decision(evidence_observation_id: observation.id, subject_state_digest: other_digest())
        )
      end

    assert error.predicate == @predicate
    assert error.expected == input_hash()
    assert error.recorded == other_digest()

    # Nothing written — the assertion is pre-transaction.
    refute current()

    # Same outcome on the struct form and on the verdict path.
    assert_raise AshJudgments.Facts.Errors.EvidenceMismatch, fn ->
      Materialiser.materialise(
        decision(evidence_observation: observation, subject_state_digest: other_digest())
      )
    end

    assert_raise AshJudgments.Facts.Errors.EvidenceMismatch, fn ->
      Materialiser.materialise_verdict(%{
        subject: @subject,
        predicate: @predicate,
        value: "urgent",
        holds: true,
        admission_id: Ash.UUID.generate(),
        subject_state_digest: other_digest(),
        evidence_observation_id: observation.id
      })
    end

    refute current()
  end

  # --- (c) replay determinism -------------------------------------------------------

  test "the assertion holds identically under materialise(clear+replay)" do
    # Three immutable observations; the sequence cites them. Replay
    # (clear facts, re-apply the same recorded calls) re-reads the SAME
    # ledger rows, so the assertion must re-verify identically.
    obs_a = record_observation!(id: fixed_uuid("a"), state_digest: input_hash())
    obs_b = record_observation!(id: fixed_uuid("b"), state_digest: other_digest())

    sequence = [
      admitted(1, obs_a.id, input_hash(), "urgent", true),
      admitted(2, obs_b.id, other_digest(), "routine", false),
      admitted(3, obs_a.id, input_hash(), "urgent", true)
    ]

    live = run_sequence(sequence)

    AshJudgments.TestRepo.query!("DELETE FROM test_facts")

    replayed = run_sequence(sequence)

    assert replayed == live, "replay must re-verify and rebuild identically"

    assert {outcomes, _snapshot} = replayed
    assert outcomes == [:materialised, :materialised, :materialised]
  end

  # --- (d) the absent path never reads the ledger ---------------------------------

  test "a nil-or-absent reference never reads the observation ledger" do
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.CountingLedger)
    AshJudgments.Test.CountingLedger.reset_read_count()

    # Control: WITH a reference the read goes through the configured
    # counting ledger — one read attempt, counted — and the double holds
    # no data, so the call fails loud rather than writing anything.
    control_outcome =
      try do
        Materialiser.materialise(decision(evidence_observation_id: Ash.UUID.generate()))
        :returned
      rescue
        e -> {:raised, e}
      end

    assert {:raised, _} = control_outcome
    assert AshJudgments.Test.CountingLedger.read_count() >= 1
    refute current()

    # The absent path: the ordinary call — zero ledger reads.
    AshJudgments.Test.CountingLedger.reset_read_count()

    assert {:ok, :materialised} = Materialiser.materialise(decision())
    assert AshJudgments.Test.CountingLedger.read_count() == 0

    # An explicit nil reference: same silence. (Idempotent — the absent
    # call above already wrote the fact — so either silent verdict.)
    AshJudgments.Test.CountingLedger.reset_read_count()

    assert {:ok, verdict} =
             Materialiser.materialise(
               decision(evidence_observation_id: nil, evidence_observation: nil)
             )

    assert verdict in [:materialised, :unchanged]
    assert AshJudgments.Test.CountingLedger.read_count() == 0

    # The preloaded struct also skips the read entirely. (Idempotent, so
    # either silent verdict.)
    AshJudgments.Test.CountingLedger.reset_read_count()

    observation = %AshJudgments.Test.CountingLedger{
      id: Ash.UUID.generate(),
      state_digest: input_hash()
    }

    assert {:ok, verdict} =
             Materialiser.materialise(decision(evidence_observation: observation))

    assert verdict in [:materialised, :unchanged]
    assert AshJudgments.Test.CountingLedger.read_count() == 0
  end

  # --- helpers ----------------------------------------------------------------------

  defp decision(overrides \\ []) do
    Keyword.merge(
      [
        result: :admitted,
        subject: @subject,
        predicate: @predicate,
        value: "urgent",
        holds: true,
        grade: :grant,
        admission_id: Ash.UUID.generate(),
        subject_state_digest: input_hash()
      ],
      overrides
    )
    |> Map.new()
  end

  # A replay-deterministic admitted decision: pinned id, pinned
  # effective_at, citing its observation (the caller's idempotency key —
  # exactly what a replay re-applies).
  defp admitted(i, observation_id, digest, value, holds) do
    decision(
      id: fixed_uuid(Integer.to_string(i)),
      subject_state_digest: digest,
      value: value,
      holds: holds,
      evidence_observation_id: observation_id,
      effective_at: DateTime.add(~U[2026-01-01 00:00:00Z], i * 3600, :second)
    )
  end

  defp run_sequence(sequence) do
    outcomes =
      Enum.map(sequence, fn step ->
        {:ok, verdict} = Materialiser.materialise(step)
        verdict
      end)

    {outcomes, snapshot_table()}
  end

  defp snapshot_table do
    # The envelope-class columns only (the facts_test discipline),
    # normalized and sorted.
    Fact
    |> Ash.Query.select([
      :id,
      :subject,
      :subject_id,
      :predicate,
      :value,
      :holds,
      :subject_state_digest,
      :admission_grade,
      :admission_id,
      :valid_at
    ])
    |> Ash.read!()
    |> Enum.map(fn fact ->
      fact
      |> Map.from_struct()
      |> Map.drop([:__metadata__, :__spark_metadata__])
      |> Map.new(fn {k, v} -> {k, normalize(v)} end)
    end)
    |> Enum.sort()
  end

  defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize(v), do: v

  defp record_observation!(overrides \\ []) do
    inputs =
      Keyword.merge(
        [
          id: Ash.UUID.generate(),
          question_id: @predicate,
          question_hash: "sha256:" <> String.duplicate("a", 64),
          question_version: 1,
          family: "clinic_triage",
          subject_type: @subject["type"],
          subject_id: @subject["id"],
          state_digest: input_hash(),
          answer_kind: :choice,
          value: "urgent",
          probabilities: %{"urgent" => "0.9", "insufficient" => "0.1"},
          confidence: Decimal.new("0.9"),
          model_spec_requested: "typesafe:test-model",
          profile: "test_local"
        ],
        overrides
      )

    Judgment
    |> Ash.Changeset.for_create(:record, inputs)
    |> Ash.create!()
  end

  defp current do
    Fact
    |> Ash.Query.for_read(:for_subject, %{subject: @subject, predicate: @predicate})
    |> Ash.read_one!(authorize?: false)
  end

  defp fixed_uuid(suffix) when is_binary(suffix) do
    "cccccccc-1111-4111-8111-" <> String.pad_leading(suffix, 12, "0")
  end
end
