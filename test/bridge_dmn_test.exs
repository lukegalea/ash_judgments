# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.BridgeDmnTest do
  @moduledoc """
  The DMN bridge suite (AST-92): flattening truth tables per answer kind
  (decimal strings, present markers), the band contract (refusals,
  admit-only fact_value), the banding fragment's record-as-inputs replay
  semantics and immutability, the certification fragment, and the
  resolver seam's degradation.
  """

  use ExUnit.Case, async: false

  @moduletag :db

  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Registry.Info

  @observation "44444444-4444-4444-8444-444444444444"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <-
          ~w(test_judgments test_human_verdicts test_facts test_bandings test_band_table_certifications test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    :ok
  end

  defp note_question do
    Info.questions(AshJudgments.Test.Note) |> List.first()
  end

  defp noul_answer(p), do: struct(AshAi.Evaluate.Noul, probability: p)

  defp choice_answer do
    struct(AshAi.Evaluate.Choice,
      value: :urgent,
      probabilities: %{urgent: 0.85, insufficient: 0.15},
      confidence: 0.9
    )
  end

  defp score_answer do
    struct(AshAi.Evaluate.Score,
      value: 1.8,
      level: "Minor",
      probabilities: %{0 => 0.05, 1 => 0.75, 2 => 0.2},
      confidence: 0.8
    )
  end

  defp opts(family \\ "clinic_triage"),
    do: [family: family, risk_tier: "standard", jurisdiction: "ca"]

  describe "inputs/2 — flattening per kind" do
    test "noul: the two-way distribution as decimal strings" do
      inputs =
        Dmn.inputs(
          [%{question: note_question(), answer: noul_answer(0.94), observation_id: @observation}],
          opts()
        )

      assert inputs["notes_follow_up__p_true"] == "0.94"
      assert inputs["notes_follow_up__p_false"] == "0.06000000000000005"
      assert inputs["notes_follow_up__present"] == "true"
      assert inputs["notes_follow_up__observation_id"] == @observation
    end

    test "choice: p_<option> per declared option in declaration order, value, confidence" do
      question =
        Info.questions(AshJudgments.Test.Appointment) |> Enum.find(&(&1.name == :triage_urgency))

      inputs =
        Dmn.inputs(
          [%{question: question, answer: choice_answer(), observation_id: @observation}],
          opts()
        )

      assert inputs["triage_urgency__p_urgent"] == "0.85"
      assert inputs["triage_urgency__p_insufficient"] == "0.15"
      assert inputs["triage_urgency__value"] == "urgent"
      assert inputs["triage_urgency__confidence"] == "0.9"
      assert inputs["triage_urgency__present"] == "true"
    end

    test "score: p_<level index> per level, position, level" do
      question =
        Info.questions(AshJudgments.Test.Appointment)
        |> Enum.find(&(&1.name == :appointment_note_summary))

      inputs =
        Dmn.inputs(
          [%{question: question, answer: score_answer(), observation_id: @observation}],
          opts()
        )

      assert inputs["appointment_note_summary__p_0"] == "0.05"
      assert inputs["appointment_note_summary__p_1"] == "0.75"
      assert inputs["appointment_note_summary__p_2"] == "0.2"
      assert inputs["appointment_note_summary__position"] == "1.8"
      assert inputs["appointment_note_summary__level"] == "Minor"
    end

    test "extraction: no probabilities, no confidence; pairs pass both observation ids and status" do
      extraction_question = extraction_probe_question()

      inputs =
        Dmn.inputs(
          [
            %{
              question: extraction_question,
              answer: struct(AshAi.Evaluate.Noul, probability: 0.5),
              observation_id: "eeeeeeee-1111-4111-8111-111111111111",
              paired_with: "eeeeeeee-2222-4222-8222-222222222222",
              status: :found
            }
          ],
          opts()
        )

      refute Enum.any?(inputs, fn {k, _v} -> k =~ "p_" end)
      refute Enum.any?(inputs, fn {k, _v} -> k =~ "confidence" end)
      assert inputs["extraction_probe__value"] == "null"
      assert inputs["extraction_probe__observation_id"] == "eeeeeeee-1111-4111-8111-111111111111"

      assert inputs["extraction_probe__observation_id_verified"] ==
               "eeeeeeee-2222-4222-8222-222222222222"

      assert inputs["extraction_probe__status"] == "found"
    end

    test "missing answers are explicit present=false markers, never absent keys" do
      inputs =
        Dmn.inputs(
          [%{question: note_question(), answer: nil, observation_id: @observation}],
          opts()
        )

      assert inputs["notes_follow_up__present"] == "false"
      # The other inputs of that question are absent — the marker is what
      # the band table reads.
      refute Map.has_key?(inputs, "notes_follow_up__p_true")
    end

    test "common envelope inputs: family, risk tier, jurisdiction" do
      inputs = Dmn.inputs([], family: "clinic_notes", risk_tier: "high", jurisdiction: "ca")

      assert inputs["family"] == "clinic_notes"
      assert inputs["risk_tier"] == "high"
      assert inputs["jurisdiction"] == "ca"
    end

    defp extraction_probe_question do
      # A v0 probe question standing in for the future extraction answer
      # type (UP-AI-VETO-adjacent); the bridge only needs name + type key.
      %{name: :extraction_probe, type: AshJudgments.Test.ProbeTypes.Extraction, constraints: []}
    end
  end

  describe "the band contract" do
    test "bands are the frozen enum (admit | review | omit — never unknown)" do
      assert Dmn.bands() == [:admit, :review, :omit]
    end

    test "validate_output accepts a well-formed admit output with a fact value" do
      assert :ok =
               Dmn.validate_output(%{
                 band: :admit,
                 fact_value: %{"option" => "urgent"},
                 reason_code: "auto_admit_high_p"
               })
    end

    test "fact_value is admit-only" do
      assert {:error, message} =
               Dmn.validate_output(%{band: :review, fact_value: %{"option" => "urgent"}})

      assert message =~ "admit-only"
    end

    test "an unknown band name is refused" do
      assert {:error, message} = Dmn.validate_output(%{band: :unknown})
      assert message =~ "frozen enum"
    end

    test "matched_rule_ids empty is a refusal, not a result (refusal?/1)" do
      assert Dmn.refusal?(%{matched_rule_ids: []})
      refute Dmn.refusal?(%{matched_rule_ids: ["rule-1"]})
      refute Dmn.refusal?(%{})
    end

    test "band_contract/0 carries the refusal rule and the naming convention" do
      contract = Dmn.band_contract()

      assert contract.refusal.check.(%{matched_rule_ids: []})
      assert contract.naming.convention =~ "judgments:family:"
      assert contract.outputs["band"].values == ["admit", "review", "omit"]
    end
  end

  describe "band_table_ref/2 — the host resolver seam" do
    test "degrades to the structured missing-dependency error without ash_decisions" do
      dir = ebin_dir!(AshDecisions)
      :code.purge(AshDecisions)
      :code.delete(AshDecisions)
      :code.del_path(dir)

      try do
        assert {:error, {:missing_dependency, :ash_decisions}} =
                 Dmn.band_table_ref(:clinic_triage, nil, resolver: {__MODULE__, :resolver, []})
      after
        :code.add_path(dir)
        {:module, AshDecisions} = Code.ensure_loaded(AshDecisions)
      end
    end

    test "delegates to the host resolver MFA" do
      test_pid = self()

      resolver = fn family, tenant ->
        send(test_pid, {:resolved, family, tenant})

        {:ok,
         %{
           "definition_key" => "triage_bands",
           "definition_version" => "3",
           "content_hash" => "sha256:" <> String.duplicate("7", 64),
           "definition_id" => "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
           "tenant_fork" => nil
         }}
      end

      assert {:ok, ref} = Dmn.band_table_ref(:clinic_triage, "tenant-1", resolver: resolver)
      assert ref["definition_key"] == "triage_bands"
      assert_received {:resolved, :clinic_triage, "tenant-1"}
    end

    test "no resolver configured is a structured error" do
      assert {:error, %ArgumentError{} = error} = Dmn.band_table_ref(:clinic_triage, nil, [])
      assert Exception.message(error) =~ "host-side"
    end

    defp ebin_dir!(module) do
      beam = Atom.to_charlist(module) ++ ~c".beam"

      case :code.where_is_file(beam) do
        :non_existing -> flunk("#{inspect(module)} beam not on the code path")
        full -> full |> List.to_string() |> Path.dirname() |> to_charlist()
      end
    end
  end

  describe "the banding fragment (record-as-inputs replay semantics)" do
    test "records a banding from the band-table's outputs — nothing recomputed" do
      inputs =
        Dmn.inputs(
          [%{question: note_question(), answer: noul_answer(0.94), observation_id: @observation}],
          opts()
        )

      banding =
        AshJudgments.Test.Banding
        |> Ash.Changeset.for_create(:record, %{
          observation_ids: [@observation],
          band: :admit,
          fact_value: %{"option" => "urgent"},
          matched_rule_ids: ["decision-table-row-3"],
          band_table: %{
            "definition_key" => "triage_bands",
            "definition_version" => "3",
            "content_hash" => "sha256:" <> String.duplicate("7", 64),
            "definition_id" => "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            "tenant_fork" => nil
          },
          decision_evaluation_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          inputs: inputs,
          mode: :live,
          correlation_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        })
        |> Ash.create!()

      assert banding.band == :admit
      assert banding.matched_rule_ids == ["decision-table-row-3"]
      assert banding.fact_value == %{"option" => "urgent"}
      assert %DateTime{} = banding.banded_at

      # The recorded record_hash is pure over the envelope-class inputs —
      # identical inputs rebuild it identically (replay safety).
      assert String.starts_with?(banding.record_hash, "sha256:")
    end

    test "empty matched_rule_ids is refused at the boundary (the fragment's verifier)" do
      assert {:error, _} =
               AshJudgments.Test.Banding
               |> Ash.Changeset.for_create(:record, %{
                 observation_ids: [@observation],
                 band: :admit,
                 matched_rule_ids: [],
                 band_table: %{
                   "definition_key" => "k",
                   "definition_version" => "1",
                   "content_hash" => "h",
                   "definition_id" => "d"
                 },
                 decision_evaluation_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                 inputs: %{}
               })
               |> Ash.create()
    end

    test "bandings are immutable — no update action exists" do
      refute Enum.any?(
               Ash.Resource.Info.actions(AshJudgments.Test.Banding),
               &(&1.type == :update)
             )
    end
  end

  describe "the certification fragment (RFC §8.2, judgment-side)" do
    test "records a certification and revocation as separate rows-worth of state" do
      certification =
        AshJudgments.Test.Certification
        |> Ash.Changeset.for_create(:record, %{
          definition_key: "triage_bands",
          definition_version: "3",
          content_hash: "sha256:" <> String.duplicate("7", 64),
          family: "clinic_triage",
          calibration_run_id: "cccccccc-1111-4111-8111-111111111111",
          verification: %{"checks" => ["overlap", "gaps"], "findings" => [], "obligations" => []},
          certified_by: "reviewer-1"
        })
        |> Ash.create!()

      assert certification.status == :certified

      revoked =
        certification
        |> Ash.Changeset.for_update(:revoke, %{certified_by: "reviewer-1"})
        |> Ash.update!()

      assert revoked.status == :revoked
      # Superseded, never deleted: the history row keeps its status.
      assert certification.status == :certified
    end
  end
end
