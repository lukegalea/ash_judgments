# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshJudgments.Calibrate do
  @shortdoc "Computes a family's calibration metrics and records the §8.1 run"
  @moduledoc """
  The calibration-run harness (S1-25): for one family, load the
  labelled pairs, compute the §8.1 metrics and the conformal threshold
  through the package's own modules (`Calibration.Metrics`,
  `Calibration.RiskControl`), hand the run to
  `Calibration.propose_band_table/3`, and record the run through the
  host's store — the §8.1 `CalibrationRun` fragment — with the proposal
  (or the honest negative result) on it.

      mix ash_judgments.calibrate clinic_notes
      mix ash_judgments.calibrate clinic_notes --source shadow_ledger
      mix ash_judgments.calibrate clinic_notes --dry-run

  `--source` is the run's provenance — `eval_set` (default) or
  `shadow_ledger`. `--dry-run` prints the metrics, the proposal and its
  DMN rendering without recording anything. A refused proposal is still
  a recorded run (`result: :no_table` — negative results are kept, ADR
  0047 point 7); the trigger itself never writes.

  ## The two host-supplied seams, stated plainly

  **The labelled pairs** (the package never sees a model or an eval
  store): the harness reads the family's pairs through an MFA seam —

      config :ash_judgments, :calibration_input, {MyApp.EvalSets, :load, []}
      # load(family, source) -> {:ok, input} | {:error, reason}

  where `input` is

      %{
        answer_kind: :noul | :choice | :score | :extraction,
        pairs: [...],                       # the Metrics pair shapes, per kind
        scored: [{score, gold_supports?}],  # the §3 conformal pairs
        question_hashes: ["sha256:…"],      # usually one
        model_version: "…", model_digest: "sha256:…", runtime_version: "…",
        eval_set_hash: "sha256:…", region: "…",
        # optional: pass_bar, n_per_class (computed for :choice),
        # observations_digest, tenant, risk_tier, created_by
      }

  **The store** (the §8.1 rows live on the host's repo, the ledger
  precedent) —

      config :ash_judgments, :calibration_store, MyApp.CalibrationRun
      # the host resource instantiating AshJudgments.Calibration.Fragment

  Without the input seam the task REFUSES — it would rather refuse than
  fabricate pairs. Without the store the task refuses on the recording
  path (a `--dry-run` needs no store, and says so honestly: nothing is
  recorded). Rendering of a proposal goes through
  `AshJudgments.Calibration.ProposalDmn` — pure, dependency-free; what
  the host does with the document (review, certify, publish) stays the
  host's and ash_decisions' business.
  """

  use Mix.Task

  # app.config + compile: the task reads the compiled fragment's
  # contract and the host's configured modules; it must not boot queues
  # or endpoints (law 23).
  @requirements ["app.config", "compile"]

  @switches [source: :string, dry_run: :boolean]
  @sources ~w(eval_set shadow_ledger)

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    family =
      case argv do
        [family] ->
          family

        [] ->
          Mix.raise("ash_judgments.calibrate requires a FAMILY argument")

        other ->
          Mix.raise("ash_judgments.calibrate takes exactly one FAMILY, got: #{inspect(other)}")
      end

    source = parse_source(opts[:source] || "eval_set")
    input = load_input(family, source)

    run_input =
      build_run(family, source, input,
        # The row's id is minted BEFORE the proposal so the recorded
        # proposal's run_id names its row (the fragment's documented
        # caller-supplied id — the harness idempotency pattern). The
        # dry run carries nil and says so.
        id: if(opts[:dry_run], do: nil, else: Ash.UUID.generate()),
        finished_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )

    case propose(run_input) do
      {:ok, proposal} -> propose_ok(family, source, run_input, proposal, opts)
      {:error, findings} -> propose_refused(family, source, run_input, findings, opts)
    end
  end

  ## The two outcomes

  # The one key the §8.1 create must not see: :answer_kind is
  # print-only, the schema has no such column. (:id IS recorded — the
  # caller-supplied idempotency key.)
  @create_drop [:answer_kind]

  defp propose_ok(family, source, run_input, proposal, opts) do
    recorded_proposal = stringify(proposal)
    {:ok, xml} = AshJudgments.Calibration.ProposalDmn.render(recorded_proposal)

    if opts[:dry_run] do
      say_head(family, source, run_input)
      say_proposal(proposal)
      say_dmn(xml, "(dry run — nothing recorded)")
    else
      store = store!()

      attrs =
        run_input
        |> Map.drop(@create_drop)
        |> Map.put(:result, :proposed_table)
        |> Map.put(:proposed_band_table, recorded_proposal)
        |> Map.to_list()

      run =
        store
        |> Ash.Changeset.for_create(:record, attrs)
        |> Ash.create!()

      say_head(family, source, run_input)
      say_proposal(proposal)
      Mix.shell().info("recorded: #{run.id} (record_hash #{run.record_hash})")
      say_dmn(xml, "proposal recorded on the run; publication stays ash_decisions' lifecycle")
    end
  end

  defp propose_refused(family, source, run_input, findings, opts) do
    if opts[:dry_run] do
      say_head(family, source, run_input)
      say_findings(findings)
      Mix.shell().info("dry run — nothing recorded, and a refusal never writes")
    else
      store = store!()

      attrs =
        run_input |> Map.drop(@create_drop) |> Map.put(:result, :no_table) |> Map.to_list()

      run =
        store
        |> Ash.Changeset.for_create(:record, attrs)
        |> Ash.create!()

      say_head(family, source, run_input)
      say_findings(findings)
      Mix.shell().info("recorded: #{run.id} (record_hash #{run.record_hash})")
      Mix.shell().info("result: :no_table — negative results are kept (ADR 0047 point 7)")
    end
  end

  ## Printing

  defp say_head(family, source, run_input) do
    Mix.shell().info("calibration run for family #{family} (source: #{source})")
    Mix.shell().info("  n = #{run_input.n}, answer_kind = #{run_input.answer_kind}")
    Mix.shell().info("  metrics: #{inspect(run_input.metrics)}")
    Mix.shell().info("  conformal thresholds: #{inspect(run_input.conformal_thresholds)}")
  end

  defp say_proposal(proposal) do
    Mix.shell().info("proposal: #{inspect(proposal)}")
  end

  defp say_findings(findings) do
    Mix.shell().info("proposal refused:")

    Enum.each(findings, fn finding -> Mix.shell().info("  - #{inspect(finding)}") end)
  end

  defp say_dmn(xml, note) do
    Mix.shell().info("DMN rendering (#{note}):")
    Mix.shell().info(xml)
  end

  ## The seams

  defp load_input(family, source) do
    seam =
      Application.get_env(:ash_judgments, :calibration_input) ||
        Mix.raise("""
        ash_judgments.calibrate cannot load labelled pairs: configure the
        input seam and re-run. The package never sees a model or an eval
        store, so the pairs must come from the host:

            config :ash_judgments, :calibration_input, {MyApp.EvalSets, :load, []}
            # load(family, source) -> {:ok, input} | {:error, reason}
        """)

    case apply_seam(seam, [family, source]) do
      {:ok, input} when is_map(input) ->
        input

      {:error, reason} ->
        Mix.raise("ash_judgments.calibrate: the input seam refused: #{inspect(reason)}")

      other ->
        Mix.raise(
          "ash_judgments.calibrate: the input seam must return {:ok, input} | {:error, reason}, got: #{inspect(other)}"
        )
    end
  end

  defp store! do
    Application.get_env(:ash_judgments, :calibration_store) ||
      Mix.raise("""
      ash_judgments.calibrate cannot record: configure the host's
      §8.1 store (a resource instantiating AshJudgments.Calibration.Fragment):

          config :ash_judgments, :calibration_store, MyApp.CalibrationRun

      or run with --dry-run to print without recording.
      """)
  end

  defp apply_seam({m, f, a}, extra), do: apply(m, f, extra ++ a)
  defp apply_seam(fun, extra) when is_function(fun), do: apply(fun, extra)

  defp parse_source(raw) when raw in @sources, do: String.to_existing_atom(raw)

  defp parse_source(raw),
    do: Mix.raise("--source must be one of #{Enum.join(@sources, " | ")}, got: #{inspect(raw)}")

  ## The §8.1 run assembly — Metrics + RiskControl, nothing invented

  # The map the proposal trigger reads (duck-typed run). The recording
  # path carries the pre-minted id; the dry run carries nil and says so.
  defp build_run(family, source, input, opts) do
    pairs = Map.fetch!(input, :pairs)
    kind = Map.fetch!(input, :answer_kind)
    metrics = metrics(kind, pairs)

    %{
      id: Keyword.fetch!(opts, :id),
      # Printed, never recorded: the fragment's schema has no such column.
      answer_kind: kind,
      family: family,
      question_hashes: Map.fetch!(input, :question_hashes),
      model_version: Map.fetch!(input, :model_version),
      model_digest: Map.fetch!(input, :model_digest),
      runtime_version: Map.fetch!(input, :runtime_version),
      eval_set_hash: Map.fetch!(input, :eval_set_hash),
      region: Map.fetch!(input, :region),
      n: length(pairs),
      n_per_class: n_per_class(kind, pairs, input),
      metrics: metrics,
      ece: metrics["ece"],
      brier: metrics["brier"],
      conformal_thresholds: conformal_thresholds(family, input),
      source: source,
      created_by: input[:created_by] || "mix ash_judgments.calibrate",
      observations_digest: input[:observations_digest],
      tenant: input[:tenant],
      risk_tier: input[:risk_tier],
      pass_bar: input[:pass_bar] || %{},
      finished_at: Keyword.fetch!(opts, :finished_at)
    }
  end

  defp metrics(:noul, pairs), do: AshJudgments.Calibration.Metrics.noul_metrics(pairs)
  defp metrics(:choice, pairs), do: AshJudgments.Calibration.Metrics.choice_metrics(pairs)
  defp metrics(:score, pairs), do: AshJudgments.Calibration.Metrics.score_metrics(pairs)

  defp metrics(:extraction, pairs),
    do: AshJudgments.Calibration.Metrics.extraction_metrics(pairs)

  defp metrics(kind, _pairs), do: Mix.raise("unknown answer_kind #{inspect(kind)}")

  # For :choice the per-class sizes come from the gold labels; other
  # kinds take the seam's map (defaults to none).
  defp n_per_class(:choice, pairs, _input) do
    Map.new(Enum.frequencies_by(pairs, &to_string(Map.get(&1, :gold))))
  end

  defp n_per_class(_kind, _pairs, input), do: input[:n_per_class] || %{}

  # The earned threshold at the family's α — never hand-set (ADR 0041).
  # An absent λ̂ (the family cannot certify at this α) records an empty
  # map: the proposal trigger's honest refusal, nothing quieter.
  defp conformal_thresholds(family, input) do
    alpha = AshJudgments.Calibration.FamilyConfig.alpha(family)
    scored = Map.get(input, :scored, [])

    case AshJudgments.Calibration.RiskControl.threshold(scored, alpha) do
      nil -> %{}
      lambda -> %{Float.to_string(alpha) => %{"threshold" => decimal_string(lambda)}}
    end
  end

  defp propose(run_input) do
    band_input = %{
      question_hash: List.first(run_input.question_hashes),
      model_digest: run_input.model_digest,
      runtime_version: run_input.runtime_version,
      region: run_input.region
    }

    AshJudgments.Calibration.propose_band_table(run_input, band_input)
  end

  # The recorded proposal is the string-keyed form — the :map
  # attribute's stored shape, and what ProposalDmn renders.
  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(v), do: v

  defp decimal_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)
  defp decimal_string(value), do: to_string(value)
end
