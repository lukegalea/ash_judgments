# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.ProposalDmnTest do
  @moduledoc """
  S1-25: the proposal's DMN rendering — the golden document for a fixed
  recorded proposal, the string/atom key equivalence, the score-input
  override, and the structural validation refusals.
  """

  use ExUnit.Case, async: true

  alias AshJudgments.Calibration.ProposalDmn

  @proposal %{
    "definition_key" => "bands_clinic_triage",
    "family_tag" => "judgments:family:clinic_triage",
    "run_id" => "0199e6a2-0000-7000-8000-000000000000",
    "question_hash" => "sha256:" <> String.duplicate("a", 64),
    "model_digest" => "sha256:" <> String.duplicate("b", 64),
    "runtime_version" => "0.7.5",
    "region" => "ca",
    "alpha" => "0.016",
    "thresholds" => %{"threshold" => "0.93"},
    "note" => "PROPOSED — never published here; a person certifies, ash_decisions activates"
  }

  @golden """
          <?xml version="1.0" encoding="UTF-8"?>
          <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                       id="bands_clinic_triage_definitions"
                       name="bands_clinic_triage"
                       namespace="https://ash-judgments.test/bands_clinic_triage"
                       expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                       typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
            <inputData id="input_p_supports" name="p_supports">
              <variable id="var_p_supports" name="p_supports" typeRef="number"/>
            </inputData>
            <decision id="decision_bands_clinic_triage" name="bands_clinic_triage">
              <variable id="var_bands_clinic_triage" name="bands_clinic_triage" typeRef="string"/>
              <informationRequirement id="req_p_supports">
                <requiredInput href="#input_p_supports"/>
              </informationRequirement>
              <decisionTable id="table_bands_clinic_triage" hitPolicy="UNIQUE" outputLabel="band">
                <input id="clause_p_supports" label="Conformal score">
                  <inputExpression id="expr_p_supports" typeRef="number">
                    <text>p_supports</text>
                  </inputExpression>
                </input>
                <output id="clause_band" name="band" label="band" typeRef="string"/>
                <output id="clause_reason_code" name="reason_code" label="reason_code" typeRef="string"/>
                <rule id="rule_admit">
                  <inputEntry id="rule_admit_0"><text>&gt;= 0.93</text></inputEntry>
                  <outputEntry id="rule_admit_1"><text>"admit"</text></outputEntry>
                  <outputEntry id="rule_admit_2"><text>"conformal_threshold_met"</text></outputEntry>
                </rule>
                <rule id="rule_review">
                  <inputEntry id="rule_review_0"><text>&lt; 0.93</text></inputEntry>
                  <outputEntry id="rule_review_1"><text>"review"</text></outputEntry>
                  <outputEntry id="rule_review_2"><text>"below_conformal_threshold"</text></outputEntry>
                </rule>
              </decisionTable>
            </decision>
          </definitions>
          """
          |> String.trim_trailing("\n")

  describe "the golden rendering" do
    test "a fixed recorded proposal renders the golden document" do
      assert {:ok, xml} = ProposalDmn.render(@proposal)
      assert xml == @golden
    end

    test "atom keys render identically to the stored string keys" do
      # The literal atom-keyed form of @proposal (no String.to_atom on
      # dynamic input — law 10).
      atom_proposal = %{
        definition_key: "bands_clinic_triage",
        family_tag: "judgments:family:clinic_triage",
        run_id: "0199e6a2-0000-7000-8000-000000000000",
        question_hash: "sha256:" <> String.duplicate("a", 64),
        model_digest: "sha256:" <> String.duplicate("b", 64),
        runtime_version: "0.7.5",
        region: "ca",
        alpha: "0.016",
        thresholds: %{"threshold" => "0.93"},
        note: "PROPOSED — never published here; a person certifies, ash_decisions activates"
      }

      assert {:ok, xml} = ProposalDmn.render(atom_proposal)
      assert xml == @golden
    end

    test "the two-band table over the conformal score, no default rule" do
      assert {:ok, xml} = ProposalDmn.render(@proposal)

      assert xml =~ ~s(hitPolicy="UNIQUE")
      # The frozen band enum's admit/review outputs, with reason codes.
      assert xml =~ ~s(<text>"admit"</text>)
      assert xml =~ ~s(<text>"review"</text>)
      # No default rule: a non-numeric score matches nothing — the
      # empty matched_rule_ids refusal (ADR 0041).
      refute xml =~ ~s(<text>-</text>)
      # Exactly what the run earned — nothing invented.
      refute xml =~ "fact_value"
      refute xml =~ "omit"
    end

    test "the score input is overridable" do
      assert {:ok, xml} = ProposalDmn.render(@proposal, score_input: "p_true")

      assert xml =~ ~s(name="p_true")
      assert xml =~ ~s(<text>p_true</text>)
      refute xml =~ "p_supports"
    end

    test "thresholds carry only the earned threshold; extra keys are not invented into the table" do
      proposal =
        Map.put(@proposal, "thresholds", %{
          "threshold" => "0.93",
          "cost" => %{"review" => "0.1", "admit" => "0.01"}
        })

      assert {:ok, xml} = ProposalDmn.render(proposal)
      assert xml == @golden
    end
  end

  describe "structural validation (a malformed proposal renders nothing)" do
    test "a non-map is refused" do
      assert {:error, [finding]} = ProposalDmn.render("bands_clinic_triage")
      assert finding =~ "must be a map"
    end

    test "a missing definition_key is refused" do
      assert {:error, findings} = ProposalDmn.render(Map.delete(@proposal, "definition_key"))
      assert Enum.any?(findings, &(&1 =~ "definition_key"))
    end

    test "an empty definition_key is refused" do
      assert {:error, findings} = ProposalDmn.render(%{@proposal | "definition_key" => "  "})
      assert Enum.any?(findings, &(&1 =~ "definition_key"))
    end

    test "a family_tag without the frozen prefix is refused" do
      assert {:error, findings} =
               ProposalDmn.render(%{@proposal | "family_tag" => "clinic_triage"})

      assert Enum.any?(findings, &(&1 =~ "family_tag"))
    end

    test "missing thresholds are refused" do
      assert {:error, findings} = ProposalDmn.render(Map.delete(@proposal, "thresholds"))
      assert Enum.any?(findings, &(&1 =~ "thresholds"))
    end

    test "a non-decimal threshold is refused" do
      assert {:error, findings} =
               ProposalDmn.render(%{@proposal | "thresholds" => %{"threshold" => "hand-set"}})

      assert Enum.any?(findings, &(&1 =~ "must parse as a decimal"))
    end

    test "a threshold outside [0, 1] is refused" do
      assert {:error, findings} =
               ProposalDmn.render(%{@proposal | "thresholds" => %{"threshold" => "1.5"}})

      assert Enum.any?(findings, &(&1 =~ "within [0, 1]"))

      assert {:error, findings} =
               ProposalDmn.render(%{@proposal | "thresholds" => %{"threshold" => "-0.1"}})

      assert Enum.any?(findings, &(&1 =~ "within [0, 1]"))
    end
  end
end
