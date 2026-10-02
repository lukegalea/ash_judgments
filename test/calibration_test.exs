# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.CalibrationTest do
  @moduledoc """
  AST-91: the calibration store (round-trips + replay-safety), the
  metrics per answer kind (golden numbers), the n-threshold proposal
  trigger (below/at/above), the publish-time verifier's refusals, the
  family TTL override's effect on cache freshness, and the
  family-config defaults.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Calibration
  alias AshJudgments.Calibration.{FamilyConfig, Metrics, RiskControl}
  alias AshJudgments.Registry.Canonical

  @digest "sha256:" <> String.duplicate("b", 64)
  @question_hash "sha256:" <> String.duplicate("a", 64)
  @eval_set_hash "sha256:" <> String.duplicate("e", 64)

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_calibration_runs test_calibration_samples test_judgments test_facts) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :families)
      Application.delete_env(:ash_judgments, :ledger)
      Application.put_env(:ash_judgments, :region, :ca)
    end)

    :ok
  end

  ## Fixtures

  defp run_attrs(overrides \\ []) do
    Keyword.merge(
      [
        family: "clinic_triage",
        question_hashes: [@question_hash],
        model_version: "test-model-1.0.0",
        model_digest: @digest,
        runtime_version: "0.7.5",
        eval_set_hash: @eval_set_hash,
        region: "ca",
        n: 3,
        n_per_class: %{"urgent" => 2, "routine" => 1},
        metrics: %{"ece" => "0.02", "brier" => "0.08", "accuracy" => "0.9"},
        ece: "0.02",
        brier: "0.08",
        conformal_thresholds: %{"0.016" => %{"threshold" => "0.93"}},
        source: :eval_set,
        created_by: "harness",
        result: :proposed_table,
        pass_bar: %{"accuracy" => "0.8"}
      ],
      overrides
    )
  end

  defp record_run(overrides \\ []) do
    AshJudgments.Test.CalibrationRun
    |> Ash.Changeset.for_create(:record, run_attrs(overrides))
    |> Ash.create!()
  end

  defp add_sample(n \\ 1, overrides \\ []) do
    for _ <- 1..n do
      AshJudgments.Test.CalibrationSample
      |> Ash.Changeset.for_create(:record,
        family: "clinic_triage",
        question_hash: @question_hash,
        model_digest: @digest,
        runtime_version: "0.7.5",
        region: "ca",
        observation_id: Ash.UUID.generate(),
        pair_digest: Canonical.digest({Ash.UUID.generate(), true}),
        gold_label_digest: Canonical.digest(true)
      )
      |> Ash.create!()
    end
  end

  describe "the store (round-trips + replay safety)" do
    test "a run records and reads back through the run key" do
      run = record_run()

      assert run.family == "clinic_triage"
      assert run.n == 3
      assert String.starts_with?(run.record_hash, "sha256:")

      [found] =
        AshJudgments.Test.CalibrationRun
        |> Ash.Query.for_read(:by_run_key, %{
          family: "clinic_triage",
          question_hash: @question_hash,
          model_digest: @digest,
          runtime_version: "0.7.5",
          eval_set_hash: @eval_set_hash,
          region: "ca"
        })
        |> Ash.read!()

      assert found.id == run.id
    end

    test "record_hash is pure over the inputs — identical on replay (law 2)" do
      # The same deterministic id + the same inputs: the derived hash must
      # come out identical, because the create re-scoring nothing (no
      # evaluation, no clock in the derived field).
      # The hash excludes the id (the ledger's discipline): identical
      # CONTENT rebuilds an identical hash whatever id carries it.
      first = record_run()
      second = record_run()

      assert first.record_hash == second.record_hash
      assert String.starts_with?(first.record_hash, "sha256:")

      # Different inputs (a different n) mint a different hash.
      third = record_run(n: 99)
      refute third.record_hash == first.record_hash
    end

    test "runs are append-only: a re-run adds a row, nothing updates" do
      record_run(n: 10)
      record_run(n: 20)

      runs =
        AshJudgments.Test.CalibrationRun
        |> Ash.Query.for_read(:by_family, %{family: "clinic_triage"})
        |> Ash.read!()

      assert length(runs) == 2
      assert Enum.map(runs, & &1.n) == [20, 10]
    end

    test "the accumulation counts labelled pairs per slot" do
      add_sample(3)

      count =
        AshJudgments.Test.CalibrationSample
        |> Ash.Query.for_read(:count_for, %{
          family: "clinic_triage",
          question_hash: @question_hash,
          model_digest: @digest,
          runtime_version: "0.7.5",
          region: "ca"
        })
        |> Ash.read!()

      assert length(count) == 3
    end
  end

  describe "the metrics (golden numbers per kind)" do
    test "noul: perfect predictions give ece 0 and brier 0" do
      pairs = [%{p: 1.0, gold: true}, %{p: 0.0, gold: false}]

      raw = Metrics.noul_raw(pairs)

      assert_in_delta raw.ece, 0.0, 1.0e-9
      assert_in_delta raw.brier, 0.0, 1.0e-9
    end

    test "noul: all-wrong certainty gives ece 1 and brier 1" do
      pairs = [%{p: 1.0, gold: false}, %{p: 1.0, gold: false}]

      raw = Metrics.noul_raw(pairs)

      assert_in_delta raw.ece, 1.0, 1.0e-9
      assert_in_delta raw.brier, 1.0, 1.0e-9
    end

    test "noul: a hand-computed mixed set, to 1.0e-9 (AC-1's form)" do
      # bin [0.0,0.1): p=0.0 gold=false → |conf-acc| = 0
      # bin [0.9,1.0): p=1.0 gold=false, p=0.9 gold=true
      #   conf = 0.95, acc = 0.5 → |0.95-0.5| = 0.45, weight 2/3
      # ece = 2/3 × 0.45 = 0.3
      pairs = [%{p: 0.0, gold: false}, %{p: 1.0, gold: false}, %{p: 0.9, gold: true}]

      raw = Metrics.noul_raw(pairs)

      expected_ece = 2 / 3 * abs(0.95 - 0.5)
      assert_in_delta raw.ece, expected_ece, 1.0e-9

      expected_brier = ((0.0 - 0.0) ** 2 + (1.0 - 0.0) ** 2 + (0.9 - 1.0) ** 2) / 3
      assert_in_delta raw.brier, expected_brier, 1.0e-9

      # The stored form is decimal strings (§8.1).
      stored = Metrics.noul_metrics(pairs)
      assert is_binary(stored["ece"]) and is_binary(stored["brier"])
      assert {dec, ""} = Decimal.parse(stored["ece"])
      assert_in_delta Decimal.to_float(dec), expected_ece, 1.0e-3
    end

    test "choice: per-class precision and recall" do
      pairs = [
        %{value: :urgent, gold: :urgent},
        %{value: :urgent, gold: :routine},
        %{value: :routine, gold: :routine},
        %{value: :routine, gold: :routine}
      ]

      metrics = Metrics.choice_metrics(pairs)

      # urgent: predicted 2, gold 1, correct 1 → precision 0.5, recall 1.0
      # routine: predicted 2, gold 3, correct 2 → precision 1.0, recall 2/3
      assert metrics["per_class"]["urgent"]["precision"] == "0.5"
      assert metrics["per_class"]["urgent"]["recall"] == "1.0"
      assert metrics["per_class"]["routine"]["precision"] == "1.0"

      {recall, ""} = Decimal.parse(metrics["per_class"]["routine"]["recall"])
      assert_in_delta Decimal.to_float(recall), 2 / 3, 1.0e-3
      assert metrics["accuracy"] == "0.75"
    end

    test "score: level agreement and MAE" do
      pairs = [
        %{position: 1, gold_position: 1},
        %{position: 2, gold_position: 3},
        %{position: 3, gold_position: 3}
      ]

      metrics = Metrics.score_metrics(pairs)

      {agreement, ""} = Decimal.parse(metrics["level_agreement"])
      assert_in_delta Decimal.to_float(agreement), 2 / 3, 1.0e-9
      {mae, ""} = Decimal.parse(metrics["mae"])
      assert_in_delta Decimal.to_float(mae), 1 / 3, 1.0e-3
    end

    test "extraction: the [L]6 four" do
      pairs = [
        # exact: found, value equal, ids within gold
        %{
          answer: %{status: :found, value: "2027-03-31", source_ids: ["a01"]},
          gold: %{value: "2027-03-31", source_ids: ["a01"]}
        },
        # fabricated: found, an id outside the gold's set
        %{
          answer: %{status: :found, value: "x", source_ids: ["a01", "FABRICATED"]},
          gold: %{value: "x", source_ids: ["a01"]}
        },
        # false abstention: gold has a value, answer abstained
        %{
          answer: %{status: :not_found, value: nil, source_ids: []},
          gold: %{value: "real", source_ids: ["a02"]}
        },
        # trap: valid but wrong on a trap item
        %{
          answer: %{status: :found, value: "wrong", source_ids: ["a01"]},
          gold: %{value: "right", source_ids: ["a01"]},
          trap?: true
        }
      ]

      metrics = Metrics.extraction_metrics(pairs)

      # exact = the VALUE equals gold (the [L]6 reading): items 1 and 2
      # (item 2's value matches; its fabricated citation is its own
      # metric).
      {exact, ""} = Decimal.parse(metrics["exact_match"])
      assert_in_delta Decimal.to_float(exact), 0.5, 1.0e-9

      # One of the three found answers cites outside its gold set.
      {fabricated, ""} = Decimal.parse(metrics["fabricated_citation"])
      assert_in_delta Decimal.to_float(fabricated), 1 / 3, 1.0e-9

      # Every item has a gold value here: one of four abstained.
      {abstain, ""} = Decimal.parse(metrics["false_abstention"])
      assert_in_delta Decimal.to_float(abstain), 0.25, 1.0e-9

      assert metrics["trap_wrong"] == "1.0"

      # An absent denominator is nil — honest absence, not a zero claim.
      no_traps = Metrics.extraction_metrics([hd(pairs)])
      assert no_traps["trap_wrong"] == nil
    end
  end

  describe "the risk-control arithmetic (the S1-25 interop)" do
    test "the min-n table at alpha 0.016: 62/124/187/249/312" do
      alpha = 0.016

      for {e, n} <- [{0, 62}, {1, 124}, {2, 187}, {3, 249}, {4, 312}] do
        assert RiskControl.min_calibration_n(e, alpha) == n
      end
    end

    test "tolerable errors read the same table backwards" do
      assert RiskControl.tolerable_errors(62, 0.016) == 0
      assert RiskControl.tolerable_errors(124, 0.016) == 1
      assert RiskControl.tolerable_errors(10, 0.016) == nil
    end

    test "the quantile rule picks the smallest qualifying score" do
      scored = [{0.99, true}, {0.98, true}, {0.97, false}, {0.5, false}]

      # lam=0.5: two errors → 3/5; lam=0.97: one → 2/5 = 0.4 qualifies;
      # lam=0.98/0.99: zero errors → 1/5 = 0.2 qualifies (smallest first)
      assert RiskControl.threshold(scored, 0.4) == 0.97
      assert RiskControl.threshold(scored, 0.2) == 0.98
      # An impossible budget (1/5 > 0.19 at every lam): the bound doing its job
      assert RiskControl.threshold(scored, 0.19) == nil
    end

    test "the audit alarm at m=200, alpha0=0.02 is 8" do
      assert RiskControl.alarm_threshold(200, 0.02) == 8
    end
  end

  describe "the n-threshold proposal trigger" do
    test "below min_n: refused, naming family, required n and the digest" do
      run = record_run(n: 10)

      assert {:error, [finding]} =
               Calibration.propose_band_table(run, %{question_hash: @question_hash})

      assert finding.finding == :n_below_min
      assert finding.family == "clinic_triage"
      assert finding.required_n == 62
      assert finding.actual_n == 10
      assert finding.model_digest == @digest
    end

    test "at min_n with a clean pass bar: the proposal is recorded-shaped data" do
      run = record_run(n: 62)

      assert {:ok, proposal} =
               Calibration.propose_band_table(run, %{question_hash: @question_hash})

      assert proposal.definition_key == "bands_clinic_triage"
      assert proposal.family_tag == "judgments:family:clinic_triage"
      assert proposal.model_digest == @digest
      assert proposal.thresholds == %{"threshold" => "0.93"}
      assert proposal.note =~ "PROPOSED"
      refute proposal.note =~ "publish this"

      # Nothing was certified or activated by the proposal.
      assert AshJudgments.Test.CalibrationSample
             |> Ash.read!()
             |> length() == 0
    end

    test "per-class floor: a class below min_n_per_class refuses" do
      run = record_run(n: 62, n_per_class: %{"urgent" => 2, "routine" => 60})

      Application.put_env(:ash_judgments, :families, %{clinic_triage: %{min_n_per_class: 10}})

      assert {:error, [finding]} =
               Calibration.propose_band_table(run, %{question_hash: @question_hash})

      assert finding.finding == :n_per_class_below_min
      assert finding.actual["urgent"] == 2
    end

    test "a run whose metrics miss its own pass bar proposes nothing" do
      run = record_run(n: 62, pass_bar: %{"accuracy" => "0.95"}, metrics: %{"accuracy" => "0.7"})

      assert {:error, [finding]} =
               Calibration.propose_band_table(run, %{question_hash: @question_hash})

      assert finding.finding == :metrics_miss_pass_bar
      assert finding.missed == %{"accuracy" => "0.95"}
    end
  end

  describe "the publish-time verifier (AC-3/AC-4)" do
    defp definition(overrides \\ []) do
      Keyword.merge(
        [
          family: "clinic_triage",
          model_digest: @digest,
          runtime_version: "0.7.5",
          region: "ca"
        ],
        overrides
      )
      |> Map.new()
    end

    test "no certification: refused, naming family, required n and the digest" do
      run = record_run(n: 62)

      assert {:error, [finding]} = Calibration.verify(definition(), nil, run)

      assert finding.finding == :not_certified
      assert finding.family == "clinic_triage"
      assert finding.required_n == 62
      assert finding.model_digest == @digest
    end

    test "a compliant run + a certification proceeds" do
      run = record_run(n: 62)

      assert :ok =
               Calibration.verify(definition(), %{status: :certified, certified_by: "luke"}, run)
    end

    test "n below min, wrong digest, wrong region, stale run each refuse" do
      stale_run = record_run(n: 5)

      assert {:error, findings} =
               Calibration.verify(definition(), %{status: :certified}, stale_run)

      assert Enum.any?(findings, &(&1.finding == :n_below_min))

      wrong_digest_run =
        record_run(n: 62, model_digest: "sha256:" <> String.duplicate("d", 64))

      assert {:error, findings} =
               Calibration.verify(definition(), %{status: :certified}, wrong_digest_run)

      assert Enum.any?(findings, &(&1.finding == :instrument_mismatch))

      wrong_region_run = record_run(n: 62, region: "us")

      assert {:error, findings} =
               Calibration.verify(definition(), %{status: :certified}, wrong_region_run)

      assert Enum.any?(findings, &(&1.finding == :region_mismatch))

      # A host variant whose rows may lack the hash: the verifier's
      # belt-and-suspenders check.
      no_eval_set_run = Map.put(record_run(n: 62), :eval_set_hash, nil)

      assert {:error, findings} =
               Calibration.verify(definition(), %{status: :certified}, no_eval_set_run)

      assert Enum.any?(findings, &(&1.finding == :eval_set_hash_missing))
    end

    test "a run older than max_age_days refuses" do
      run = record_run(n: 62)

      AshJudgments.TestRepo.query!(
        "UPDATE test_calibration_runs SET started_at = now() - interval '200 days'"
      )

      run = Ash.reload!(run)

      assert {:error, findings} =
               Calibration.verify(definition(), %{status: :certified}, run)

      assert Enum.any?(findings, &(&1.finding == :run_too_old))
    end
  end

  describe "the family TTL override (the AST-89 deferral)" do
    test "defaults: no families config gives the package defaults" do
      config = FamilyConfig.fetch(:some_unknown_family)

      assert config.min_n == 62
      assert config.alpha == 0.016
      assert config.max_age_days == 90
      assert config.ttl == nil
      assert config.min_n_per_class == nil

      assert FamilyConfig.ttl(:some_unknown_family) == nil
    end

    test "host overrides merge over the defaults, atom or string family" do
      Application.put_env(:ash_judgments, :families, %{
        clinic_triage: %{min_n: 200, ttl: 900, min_n_per_class: 40}
      })

      assert FamilyConfig.fetch("clinic_triage").min_n == 200
      assert FamilyConfig.fetch(:clinic_triage).ttl == 900
      assert FamilyConfig.fetch(:clinic_triage).min_n_per_class == 40
      # Untouched keys keep their defaults.
      assert FamilyConfig.fetch(:clinic_triage).alpha == 0.016
      # Other families are unaffected.
      assert FamilyConfig.fetch(:other).ttl == nil
    end

    test "the override changes cache freshness — a within-TTL record misses when ttl is 0" do
      Application.put_env(:ash_judgments, :families, %{clinic_notes: %{ttl: 0}})

      record = record_observation()

      key = %{
        state_digest: record.state_digest,
        model_digest: record.model_digest,
        runtime_version: record.runtime_version,
        wire_question_hash: record.wire_question_hash,
        zone_id: :ca
      }

      # The QUESTION's ttl is 3600 — within-TTL, a hit…
      assert AshJudgments.Cache.lookup_live(
               AshJudgments.Test.Judgment,
               AshJudgments.Ledger.cache_key(key),
               3600
             )

      # …but the family's override (ttl 0) expires everything: no hit.
      refute AshJudgments.Cache.lookup_live(
               AshJudgments.Test.Judgment,
               AshJudgments.Ledger.cache_key(key),
               0
             )

      # And the judge reads the override (a 0-second family ttl on
      # clinic_notes would turn every lookup into a miss).
      assert AshJudgments.Calibration.FamilyConfig.ttl(:clinic_notes) == 0
    end

    defp record_observation do
      AshJudgments.Test.Judgment
      |> Ash.Changeset.for_create(:record,
        question_id: "judgment:v0:X#judgments/y",
        question_hash: "sha256:" <> String.duplicate("a", 64),
        question_version: 1,
        family: "clinic_notes",
        subject_type: "AshJudgments.Test.Note",
        subject_id: "n1",
        state_digest: Canonical.digest(%{"x" => 1}),
        answer_kind: :noul,
        value: nil,
        probabilities: %{"true" => "0.9", "false" => "0.1"},
        confidence: Decimal.new("0.9"),
        model_spec_requested: "typesafe:test-model",
        model_version: "test-model-1.0.0",
        model_digest: @digest,
        runtime_version: "0.7.5",
        profile: "test_local",
        latency_us: 1,
        mode: :live
      )
      |> Ash.create!()
    end
  end
end
