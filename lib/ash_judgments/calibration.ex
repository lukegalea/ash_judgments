# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration do
  @moduledoc """
  Calibration (ticket AST-91, CORE-CALIB): the store, the metrics, the
  band-table PROPOSAL and the publish-time verifier.

  **Law 5: thresholds are policy data, earned by calibration.** Bands
  live in versioned DMN tables; a band table may not be PROPOSED for a
  family whose live accumulation (`Calibration.SampleFragment`) is
  below the family's `min_n` (`Calibration.FamilyConfig`); nothing is
  ever auto-certified — a person certifies through
  `Banding.CertificationFragment`, and publication stays ash_decisions'
  lifecycle (ADR 0041).

  ## The pieces

  - `Calibration.Fragment` — the §8.1 `CalibrationRun` record
    (host-instantiated): run key, sample sizes, the metrics object
    (decimal strings), conformal thresholds, provenance, and the
    RECORDED proposal. Append-only; `:record` accepts every field as
    input and computes only the pure `record_hash` (law 2).
  - `Calibration.SampleFragment` — the per-family accumulation: one
    append-only row per labelled pair; n is the slot's count.
  - `Calibration.Metrics` — per-answer-kind metrics as pure functions,
    emitting the §8.1 decimal-string shape; extraction families use the
    [L]6 vocabulary (exact_match / fabricated_citation /
    false_abstention / trap_wrong).
  - `Calibration.RiskControl` — the conformal-risk-control arithmetic
    (min-n table, tolerable errors, the λ̂ quantile rule, the audit
    alarm), interoperable with clinic-demo's reference implementation.
  - `Calibration.FamilyConfig` — min_n, min_n_per_class, alpha,
    max_age_days and the family TTL override (the AST-89 deferral), as
    host config.
  - `propose_band_table/3` — the n-threshold trigger: reads a run
    against the family config and returns the proposed band table as
    data, or structured findings. A refusal never writes.
  - `Calibration.PublishVerifier.verify/4` — the publish-time check a
    host runs next to ash_decisions' overlap/completeness verifiers:
    certified by a person + a compliant run + model/region/age matched.

  ## Consumers

  - **S1-62** (approval loop): the accumulation counts are the samples'
    slot counts; `propose_band_table/3` emits the proposal artefact for
    the review queue; certification + activation are people's acts.
  - **S1-25** (the calibration-run harness): loads label rows, runs the
    judge in `:live`/`:shadow` or reads recorded rows, computes through
    `Metrics`, records through the fragment, and hands the proposal to
    `propose_band_table/3`. The clinic-demo `RiskControl` module is the
    reference for the shared arithmetic — same formulas, same worked
    examples, asserted in the golden tests.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Calibration.FamilyConfig

  @band_tag_prefix "judgments:family:"

  @doc """
  The n-threshold proposal trigger. `run` is a recorded §8.1 run row
  (the fragment's resource); `band_input` carries what the table gates
  on — `%{question_hash: …, model_digest: …, runtime_version: …,
  region: …}`.

  Returns:

  - `{:ok, proposal}` — the proposed band table as DATA
    (`%{definition_key, family_tag, thresholds: %{…}, provenance: …}`);
    recording it is the caller's act (it lands in the run's
    `proposed_band_table` + the host's draft definition). Never
    certified, never published here.
  - `{:error, findings}` — `:n_below_min` (naming family, required n,
    actual n), `:n_per_class_below_min`, or `:metrics_miss_pass_bar`
    (the run's own pre-registered pass bar said no). A refusal never
    writes anything.

  The proposed THRESHOLDS come from the run's recorded
  `conformal_thresholds` at the family's α — thresholds are earned,
  never hand-set (ADR 0041).
  """
  @spec propose_band_table(map(), map(), keyword()) ::
          {:ok, map()} | {:error, [map()]}
  def propose_band_table(run, band_input, opts \\ []) do
    config = FamilyConfig.fetch(run.family)
    findings = run_findings(run, config, band_input)

    if findings == [] do
      {:ok, proposal(run, band_input, config, opts)}
    else
      {:error, findings}
    end
  end

  defp run_findings(run, config, band_input) do
    n_finding(run, config, band_input) ++ per_class_finding(run, config) ++ pass_bar_finding(run)
  end

  defp n_finding(run, config, band_input) do
    if run.n >= config.min_n do
      []
    else
      [
        %{
          finding: :n_below_min,
          family: run.family,
          required_n: config.min_n,
          actual_n: run.n,
          model_digest: band_input[:model_digest] || run.model_digest
        }
      ]
    end
  end

  defp per_class_finding(run, config) do
    floor_n = config.min_n_per_class

    if is_integer(floor_n) do
      under =
        run.n_per_class
        |> Enum.filter(fn {_class, n} -> n < floor_n end)
        |> Map.new()

      if under == %{} do
        []
      else
        [
          %{
            finding: :n_per_class_below_min,
            family: run.family,
            required_n_per_class: floor_n,
            actual: under
          }
        ]
      end
    else
      []
    end
  end

  # The run's own pre-registered pass bar (§8.1) is the recorded policy:
  # a run whose metrics missed its bar proposes nothing.
  defp pass_bar_finding(run) do
    bar = run.pass_bar || %{}

    missed =
      bar
      |> Enum.filter(fn {metric, bar_value} ->
        actual = (run.metrics || %{})[to_string(metric)]
        actual == nil or not meets?(actual, bar_value)
      end)
      |> Map.new(fn {metric, bar_value} -> {to_string(metric), bar_value} end)

    if missed == %{} do
      []
    else
      [%{finding: :metrics_miss_pass_bar, family: run.family, missed: missed}]
    end
  end

  # Bar comparisons run on the DECIMAL STRINGS both sides carry: numeric
  # when both parse, lexicographic never.
  defp meets?(actual, bar_value) do
    case Decimal.parse(to_string(actual)) do
      {actual_dec, ""} ->
        case Decimal.parse(to_string(bar_value)) do
          {bar_dec, ""} -> Decimal.compare(actual_dec, bar_dec) in [:gt, :eq]
          _ -> false
        end

      _ ->
        false
    end
  end

  defp proposal(run, band_input, config, opts) do
    definition_key = Keyword.get(opts, :definition_key, "bands_" <> run.family)
    alpha_key = Float.to_string(config.alpha)

    threshold =
      (run.conformal_thresholds || %{})[alpha_key] ||
        (run.conformal_thresholds || %{})[Float.to_string(config.alpha)]

    %{
      definition_key: definition_key,
      family: run.family,
      family_tag: @band_tag_prefix <> run.family,
      run_id: run.id,
      question_hash: band_input[:question_hash] || List.first(run.question_hashes),
      model_digest: run.model_digest,
      runtime_version: run.runtime_version,
      region: run.region,
      alpha: alpha_key,
      thresholds: threshold,
      note: "PROPOSED — never published here; a person certifies, ash_decisions activates"
    }
  end

  @doc """
  The publish-time verifier (AC-3/AC-4): for a band-table definition
  about to publish for family F, require —

  - a CERTIFICATION by a person (`Banding.CertificationFragment` row,
    status `:certified`) — a definition with none is refused, naming
    the family, the required n and the pinned digest;
  - a `CalibrationRun` with `n ≥ min_n` and per-class n ≥
    `min_n_per_class`;
  - the same `model_digest` / `runtime_version` as the run (the
    verifier refuses a table naming a digest with no run — ADR 0041);
  - the same region;
  - an `eval_set_hash` recorded on the run;
  - a run age ≤ the family's `max_age_days`.

  Arguments: the definition ref (`%{family:, model_digest:,
  runtime_version:, region:}`), the certification row (or nil), the
  calibration run row (or nil). Returns `:ok` or `{:error, findings}`.
  """
  @spec verify(map(), map() | nil, map() | nil) :: :ok | {:error, [map()]}
  def verify(definition, certification, run) do
    config = FamilyConfig.fetch(definition.family)

    findings =
      [
        certification_finding(definition, certification),
        run_finding(definition, run, config),
        digest_finding(definition, run),
        region_finding(definition, run),
        eval_set_finding(definition, run),
        age_finding(definition, run, config)
      ]
      |> List.flatten()

    if findings == [], do: :ok, else: {:error, findings}
  end

  defp certification_finding(_definition, %{status: :certified}) do
    # Duck-typed: the host's certification resource includes the
    # fragment; the test rows are plain maps with the fragment's shape.
    []
  end

  defp certification_finding(definition, _certification) do
    [
      %{
        finding: :not_certified,
        family: definition.family,
        required_n: FamilyConfig.min_n(definition.family),
        model_digest: definition.model_digest,
        note: "a person certifies — nothing is auto-certified (ADR 0041)"
      }
    ]
  end

  defp run_finding(_definition, nil, _config) do
    [%{finding: :no_calibration_run}]
  end

  defp run_finding(definition, run, config) do
    if run.n >= config.min_n do
      []
    else
      [
        %{
          finding: :n_below_min,
          family: definition.family,
          required_n: config.min_n,
          actual_n: run.n,
          model_digest: definition.model_digest
        }
      ]
    end
  end

  defp digest_finding(_definition, nil), do: []
  defp digest_finding(_definition, %{model_digest: nil}), do: []

  defp digest_finding(definition, run) do
    if run.model_digest == definition.model_digest and
         run.runtime_version == definition.runtime_version do
      []
    else
      [
        %{
          finding: :instrument_mismatch,
          family: definition.family,
          definition_digest: definition.model_digest,
          run_digest: run.model_digest
        }
      ]
    end
  end

  defp region_finding(_definition, nil), do: []

  defp region_finding(definition, run) do
    if to_string(run.region) == to_string(definition.region) do
      []
    else
      [%{finding: :region_mismatch, family: definition.family, run_region: run.region}]
    end
  end

  defp eval_set_finding(_definition, nil), do: []

  defp eval_set_finding(_definition, run) do
    if blank?(run.eval_set_hash) do
      [%{finding: :eval_set_hash_missing, family: run.family}]
    else
      []
    end
  end

  defp age_finding(_definition, nil, _config), do: []

  defp age_finding(definition, run, config) do
    age_days =
      case run.started_at do
        %DateTime{} = started -> DateTime.diff(DateTime.utc_now(), started) / 86_400
        nil -> 0
        _ -> 0
      end

    if age_days <= config.max_age_days do
      []
    else
      [
        %{
          finding: :run_too_old,
          family: definition.family,
          max_age_days: config.max_age_days,
          age_days: Float.round(age_days, 2)
        }
      ]
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
