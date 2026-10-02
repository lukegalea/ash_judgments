# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.CalibrateTaskTest do
  @moduledoc """
  S1-25: the calibration-run harness task — the dry run records
  nothing, the seams' absence is an honest refusal, the recording path
  lands the §8.1 row with the proposal (or the kept negative result) on
  it, and the task boots minimally (law 23: app.config + compile).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshJudgments.Test.CalibrationRun

  @digest "sha256:" <> String.duplicate("b", 64)
  @question_hash "sha256:" <> String.duplicate("a", 64)
  @eval_set_hash "sha256:" <> String.duplicate("e", 64)

  # 70 noul pairs, perfectly calibrated (ece 0), and a conformal scored
  # list whose λ̂ at α = 0.016 is 0.9 (no error qualifies: 1/71 ≤ 0.016).
  @pairs for(_ <- 1..35, do: %{p: 1.0, gold: true}) ++
           for(_ <- 1..35, do: %{p: 0.0, gold: false})

  @scored List.duplicate({0.95, true}, 35) ++ List.duplicate({0.9, true}, 35)

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_calibration_runs")

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :calibration_input)
      Application.delete_env(:ash_judgments, :calibration_store)
    end)

    :ok
  end

  defmodule Input do
    @moduledoc false
    # The test's input seam: the fixed 70-pair clinic_triage eval set.
    def load("clinic_triage", :eval_set) do
      {:ok,
       %{
         answer_kind: :noul,
         pairs: AshJudgments.CalibrateTaskTest.pairs(),
         scored: AshJudgments.CalibrateTaskTest.scored(),
         question_hashes: [AshJudgments.CalibrateTaskTest.question_hash()],
         model_version: "test-model-1.0.0",
         model_digest: AshJudgments.CalibrateTaskTest.digest(),
         runtime_version: "0.7.5",
         eval_set_hash: AshJudgments.CalibrateTaskTest.eval_set_hash(),
         region: "ca",
         # An empty bar: every metric in the §8.1 object is a loss
         # (lower is better) and the trigger's bar comparison is a
         # gain reading (≥), so a non-empty bar is covered by the
         # proposal-trigger tests, not here.
         pass_bar: %{}
       }}
    end

    def load(_family, _source), do: {:error, :unknown_family}
  end

  describe "the task path" do
    test "--dry-run prints metrics, the proposal and its DMN, and records nothing" do
      configure_seams()

      output =
        capture_io(fn ->
          Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage", "--dry-run"])
        end)

      assert output =~ "calibration run for family clinic_triage (source: eval_set)"
      assert output =~ "n = 70"
      assert output =~ ~s("ece" => "0.0")
      assert output =~ ~s("threshold" => "0.9")
      assert output =~ "bands_clinic_triage"
      assert output =~ "PROPOSED"
      assert output =~ ~s(<definitions)
      assert output =~ ~s(hitPolicy="UNIQUE")
      assert output =~ "dry run — nothing recorded"

      assert runs() == []
    end

    test "--dry-run needs no store (nothing to record)" do
      Application.put_env(:ash_judgments, :calibration_input, {Input, :load, []})
      Application.delete_env(:ash_judgments, :calibration_store)

      output =
        capture_io(fn ->
          Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage", "--dry-run"])
        end)

      assert output =~ "dry run"
      assert runs() == []
    end

    test "a recording run lands the §8.1 row with the proposal on it" do
      configure_seams()

      output =
        capture_io(fn ->
          Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage"])
        end)

      assert output =~ "recorded:"

      [run] = runs()

      assert run.family == "clinic_triage"
      assert run.n == 70
      assert run.result == :proposed_table
      assert run.ece == "0.0"
      assert run.brier == "0.0"
      assert run.conformal_thresholds == %{"0.016" => %{"threshold" => "0.9"}}
      assert run.source == :eval_set
      assert run.created_by == "mix ash_judgments.calibrate"
      assert String.starts_with?(run.record_hash, "sha256:")

      # The recorded proposal is the string-keyed draft definition,
      # linked back to the run — what ProposalDmn renders.
      assert run.proposed_band_table["definition_key"] == "bands_clinic_triage"
      assert run.proposed_band_table["run_id"] == run.id
      assert run.proposed_band_table["thresholds"] == %{"threshold" => "0.9"}

      assert output =~ run.id
    end

    test "a refused proposal records the run as :no_table (negative results are kept)" do
      configure_seams()
      # n 70 < a raised min_n of 200: the trigger refuses, the run stays.
      Application.put_env(:ash_judgments, :families, %{clinic_triage: %{min_n: 200}})

      on_exit(fn -> Application.delete_env(:ash_judgments, :families) end)

      capture_io(fn ->
        Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage"])
      end)

      [run] = runs()

      assert run.result == :no_table
      assert run.proposed_band_table == nil
      assert run.n == 70
    end
  end

  describe "the honest refusals" do
    test "no input seam: refuses, naming the config" do
      Application.delete_env(:ash_judgments, :calibration_input)

      assert_raise(Mix.Error, ~r/calibration_input/, fn ->
        Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage", "--dry-run"])
      end)
    end

    test "a refusing input seam: refuses, naming the reason" do
      Application.put_env(:ash_judgments, :calibration_input, {Input, :load, []})

      assert_raise(Mix.Error, ~r/input seam refused.*unknown_family/s, fn ->
        Mix.Tasks.AshJudgments.Calibrate.run(["no_such_family"])
      end)
    end

    test "no store on the recording path: refuses, naming the config and --dry-run" do
      Application.put_env(:ash_judgments, :calibration_input, {Input, :load, []})
      Application.delete_env(:ash_judgments, :calibration_store)

      assert_raise(Mix.Error, ~r/calibration_store.*--dry-run/s, fn ->
        Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage"])
      end)

      assert runs() == []
    end

    test "a missing FAMILY argument refuses" do
      assert_raise(Mix.Error, ~r/requires a FAMILY/, fn ->
        Mix.Tasks.AshJudgments.Calibrate.run([])
      end)
    end

    test "an unknown --source refuses" do
      assert_raise(Mix.Error, ~r/--source/, fn ->
        Mix.Tasks.AshJudgments.Calibrate.run(["clinic_triage", "--source", "somewhere"])
      end)
    end
  end

  describe "law 23 (the minimal boot)" do
    test "the task requires only app.config and compile" do
      assert Mix.Task.requirements(Mix.Tasks.AshJudgments.Calibrate) == [
               "app.config",
               "compile"
             ]
    end
  end

  def pairs, do: @pairs
  def scored, do: @scored
  def question_hash, do: @question_hash
  def digest, do: @digest
  def eval_set_hash, do: @eval_set_hash

  defp configure_seams do
    Application.put_env(:ash_judgments, :calibration_input, {Input, :load, []})
    Application.put_env(:ash_judgments, :calibration_store, CalibrationRun)
  end

  defp runs do
    CalibrationRun |> Ash.read!()
  end
end
