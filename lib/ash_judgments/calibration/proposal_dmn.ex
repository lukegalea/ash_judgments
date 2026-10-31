# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.ProposalDmn do
  @moduledoc """
  The DMN XML rendering of a PROPOSED band table (ticket S1-25) — the
  harness step that turns a recorded `CalibrationRun.proposed_band_table`
  into a publishable DMN document in the shape the host resolver
  consumes (the ash_decisions decision-table fixture shape, DMN 1.5).

  **Pure rendering.** Nothing is evaluated, nothing is published, no
  `ash_decisions` resource is touched: the module takes the proposal as
  DATA and returns the document as a string. Publication stays
  ash_decisions' lifecycle (ADR 0041); certification stays a person's
  act. It is dependency-free on purpose — hosts without `ash_decisions`
  can still render and review a proposal.

  ## The rendered table

  Conformal selective prediction renders as a decision table over the
  conformal score (the flattened evidence-style input `p_supports`,
  override with `:score_input`). With the upper threshold alone it has
  two rules:

  - `score >= λ̂` → `admit` (`reason_code` `conformal_threshold_met`);
  - `score < λ̂` → `review` (`reason_code` `below_conformal_threshold`).

  With a lower threshold (`thresholds["threshold_low"]`, see
  `AshJudgments.Calibration.RiskControl.threshold_low/2`) **and** a
  `:low_band` option it has three:

  - `score >= λ̂` → `admit` (`conformal_threshold_met`);
  - `score <= λ̂_low` → the family's low band, `reason_code`
    `conformal_low_threshold_met`: `admit` with `fact_value` `false`
    (`low_band: :admit_no`, a confident no), or `omit` (`low_band:
    :omit`, nothing is admitted);
  - between them, `(λ̂_low..λ̂)` → `review` (`below_conformal_threshold`).

  Without either one the table is the two-rule table, byte for byte.

  **`fact_value` is emitted only for `:admit_no`**, as a third output
  typed `boolean`: `false` on the low rule and `null` on the others. The
  host's banding step records the table's `fact_value` output as the
  banding's `fact_value` when the output is not null, and otherwise
  derives it from the gated answer (for a yes/no answer admitted on
  `p_true`, that is `true`). So the admit rule leaves it null and the
  yes keeps the value it has today, and a confident no is admitted as
  `false`, the same JSON boolean a yes/no fact holds. `review` and `omit`
  carry no fact value (the band contract keeps `fact_value` admit-only).

  **There is no default rule** (ADR 0041): an input that is not a number
  — an absent or malformed score — matches no row (`number/1` fails, so
  the evaluation errors), and that is a REFUSAL, not a result. Every
  rule renders a threshold the run earned; the only thing this module
  adds is what the family's `low_band` says the lower range does.

  ## Structural validation

  The proposal is validated BEFORE rendering; a malformed proposal
  renders nothing:

  - a non-empty map;
  - `definition_key` — a non-empty string (the draft definition's name);
  - `family_tag` — the frozen `judgments:family:<F>` tag naming
    (§7.1's convention);
  - `thresholds` — a map whose `"threshold"` parses as a decimal in
    `[0, 1]` (the earned λ̂), and whose `"threshold_low"`, when present,
    parses as a decimal in `[0, 1]` strictly below it. Nothing else in
    `thresholds` — a cost matrix, say — is rendered;
  - `:low_band` — `:admit_no`, `:omit` or nil.

  Keys may be strings (the `:map` attribute's stored form) or atoms
  (`propose_band_table/3`'s output) — both render identically. Errors
  come back as a list of findings; the caller decides what to do with
  them. Rendering never raises.
  """

  @moduledoc since: "0.1.0"

  @family_tag_prefix "judgments:family:"

  @doc """
  Renders a proposed band table into a DMN 1.5 XML document.

  `proposal` is the recorded `CalibrationRun.proposed_band_table` map
  (or `propose_band_table/3`'s return, atom-keyed). Options:

  - `:score_input` — the FEEL input the threshold gates on, or a list
    of them (default `"p_supports"`). Pass the names
    `AshJudgments.Bridge.Dmn.inputs/2` flattens the family's answers to,
    such as `"<question>__p_true"` for a noul question: one per question
    when the family has several. The table reads the first one present,
    so a banding over one question's answer leaves the others `null`.
    Each is declared a `string`, the bridge's decimal-string form (§4.3),
    and the table compares `number(...)` of it.
  - `:low_band` — the family's low band (`FamilyConfig.low_band/1`):
    `:admit_no`, `:omit`, or nil (the default: no lower range). It takes
    effect only when the proposal carries a `"threshold_low"`.

  Returns `{:ok, xml}` or `{:error, findings}` — a non-empty list of
  human-readable findings. Never raises.
  """
  @spec render(term(), keyword()) :: {:ok, String.t()} | {:error, [String.t()]}
  def render(proposal, opts \\ [])

  def render(proposal, opts) when is_map(proposal) and not is_struct(proposal) do
    score_inputs = opts |> Keyword.get(:score_input, "p_supports") |> List.wrap()
    low_band = Keyword.get(opts, :low_band)

    findings =
      [
        key_finding(proposal),
        tag_finding(proposal),
        threshold_finding(proposal),
        threshold_low_finding(proposal),
        score_input_finding(score_inputs),
        low_band_finding(low_band)
      ]
      |> Enum.reject(&is_nil/1)

    if findings == [] do
      {:ok, document(proposal, score_inputs, low_band)}
    else
      {:error, findings}
    end
  end

  def render(_proposal, _opts) do
    {:error, ["the proposal must be a map of the recorded proposed_band_table shape"]}
  end

  ## Structural validation

  defp low_band_finding(low_band) when low_band in [nil, :admit_no, :omit], do: nil

  defp low_band_finding(low_band),
    do: "`:low_band` must be :admit_no, :omit or nil (got: #{inspect(low_band)})"

  # A lower threshold, when present, must be a decimal in [0, 1] strictly
  # below the upper one: ranges that overlap would claim the same scores.
  defp threshold_low_finding(proposal) do
    thresholds = fetch(proposal, :thresholds)

    with true <- is_map(thresholds),
         low when not is_nil(low) <- fetch(thresholds, :threshold_low) do
      case decimal(low) do
        {:ok, value} ->
          range_finding(value) || overlap_finding(value, fetch(thresholds, :threshold))

        :error ->
          "the `thresholds[\"threshold_low\"]` must parse as a decimal in [0, 1] " <>
            "(got: #{inspect(low)})"
      end
    else
      _ -> nil
    end
  end

  defp overlap_finding(low, threshold) do
    case decimal(threshold) do
      {:ok, high} ->
        if Decimal.compare(low, high) == :lt do
          nil
        else
          "the lower threshold must be below the threshold " <>
            "(got: #{Decimal.to_string(low)} and #{Decimal.to_string(high)})"
        end

      # The upper threshold's own finding names it.
      :error ->
        nil
    end
  end

  defp score_input_finding(names) do
    if names != [] and Enum.all?(names, &(is_binary(&1) and String.trim(&1) != "")) do
      nil
    else
      "`:score_input` must be a non-empty input name or a non-empty list of them"
    end
  end

  defp key_finding(proposal) do
    key = fetch(proposal, :definition_key)

    if is_binary(key) and String.trim(key) != "" do
      nil
    else
      "the proposal needs a non-empty `definition_key` naming the draft definition"
    end
  end

  defp tag_finding(proposal) do
    tag = fetch(proposal, :family_tag)

    if is_binary(tag) and String.starts_with?(tag, @family_tag_prefix) do
      nil
    else
      "the proposal needs a `family_tag` starting with #{@family_tag_prefix <> "<F>"} " <>
        "(got: #{inspect(tag)})"
    end
  end

  defp threshold_finding(proposal) do
    thresholds = fetch(proposal, :thresholds)

    if is_map(thresholds) do
      threshold_value_finding(fetch(thresholds, :threshold))
    else
      "the proposal needs a `thresholds` map carrying the earned threshold"
    end
  end

  defp threshold_value_finding(threshold) do
    case decimal(threshold) do
      {:ok, value} ->
        range_finding(value)

      :error ->
        "the `thresholds[\"threshold\"]` must parse as a decimal in [0, 1] " <>
          "(got: #{inspect(threshold)})"
    end
  end

  defp range_finding(value) do
    low = Decimal.compare(value, Decimal.new(0)) == :lt
    high = Decimal.compare(value, Decimal.new(1)) == :gt

    if low or high do
      "the threshold must be within [0, 1] (got: #{Decimal.to_string(value)})"
    else
      nil
    end
  end

  defp decimal(nil), do: :error

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp decimal(%Decimal{} = value), do: {:ok, value}
  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp decimal(_), do: :error

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  ## The document

  defp document(proposal, score_inputs, low_band) do
    key = fetch(proposal, :definition_key)
    thresholds = fetch(proposal, :thresholds)
    threshold = fetch(thresholds, :threshold)
    id = ncname(key)

    table =
      case fetch(thresholds, :threshold_low) do
        low when not is_nil(low) and low_band != nil ->
          three_rules(threshold, low, low_band)

        _ ->
          two_rules(threshold)
      end

    # The decision's result is the outputs' context, so its variable
    # carries no typeRef: typed `string`, every evaluation is a type error.
    # The inputs are declared but not required: a family's table reads one
    # question's score, and an information requirement makes the engine
    # refuse the other questions' absent inputs.
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 id="#{id}_definitions"
                 name="#{escape(key)}"
                 namespace="https://ash-judgments.test/#{id}"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    #{Enum.map_join(score_inputs, "\n", &input_data/1)}
      <decision id="decision_#{id}" name="#{escape(key)}">
        <variable id="var_#{id}" name="#{escape(key)}"/>
        <decisionTable id="table_#{id}" hitPolicy="UNIQUE" outputLabel="band">
          <input id="clause_score" label="Conformal score">
            <inputExpression id="expr_score" typeRef="number">
              <text>#{escape(score_expression(score_inputs))}</text>
            </inputExpression>
          </input>
    #{table}
        </decisionTable>
      </decision>
    </definitions>
    """
    |> String.trim_trailing("\n")
  end

  @band_outputs """
        <output id="clause_band" name="band" label="band" typeRef="string"/>
        <output id="clause_reason_code" name="reason_code" label="reason_code" typeRef="string"/>\
  """

  @fact_value_output """
        <output id="clause_fact_value" name="fact_value" label="fact_value" typeRef="boolean"/>\
  """

  defp two_rules(threshold) do
    Enum.join(
      [
        @band_outputs,
        rule("rule_admit", ">= #{threshold}", ["admit", "conformal_threshold_met"]),
        rule("rule_review", "< #{threshold}", ["review", "below_conformal_threshold"])
      ],
      "\n"
    )
  end

  defp three_rules(threshold, low, :admit_no) do
    Enum.join(
      [
        @band_outputs,
        @fact_value_output,
        rule("rule_admit", ">= #{threshold}", ["admit", "conformal_threshold_met", :null]),
        rule("rule_admit_no", "<= #{low}", ["admit", "conformal_low_threshold_met", false]),
        rule("rule_review", "(#{low}..#{threshold})", [
          "review",
          "below_conformal_threshold",
          :null
        ])
      ],
      "\n"
    )
  end

  defp three_rules(threshold, low, :omit) do
    Enum.join(
      [
        @band_outputs,
        rule("rule_admit", ">= #{threshold}", ["admit", "conformal_threshold_met"]),
        rule("rule_omit", "<= #{low}", ["omit", "conformal_low_threshold_met"]),
        rule("rule_review", "(#{low}..#{threshold})", ["review", "below_conformal_threshold"])
      ],
      "\n"
    )
  end

  defp rule(id, input_entry, outputs) do
    entries =
      outputs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {output, i} ->
        ~s(        <outputEntry id="#{id}_#{i}"><text>#{feel(output)}</text></outputEntry>)
      end)

    """
          <rule id="#{id}">
            <inputEntry id="#{id}_0"><text>#{escape(input_entry)}</text></inputEntry>
    #{entries}
          </rule>\
    """
  end

  defp feel(:null), do: "null"
  defp feel(false), do: "false"
  # Output literals are the fixed band vocabulary: nothing to escape.
  defp feel(value) when is_binary(value), do: ~s("#{value}")

  defp input_data(name) do
    """
      <inputData id="input_#{ncname(name)}" name="#{escape(name)}">
        <variable id="var_#{ncname(name)}" name="#{escape(name)}" typeRef="string"/>
      </inputData>\
    """
  end

  # The first input present: an absent input reads `null`. When none is
  # present, or the value is not a number, `number/1` fails and no row
  # matches.
  defp score_expression([name]), do: "number(#{name})"

  defp score_expression(names) do
    {last, firsts} = List.pop_at(names, -1)

    "number(" <>
      Enum.map_join(firsts, "", &"if #{&1} != null then #{&1} else ") <> last <> ")"
  end

  # DMN ids must be NCNames; a definition key is rendered verbatim in
  # `name` and sanitised only where it becomes an id fragment.
  defp ncname(key) do
    String.replace(key, ~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(value), do: value |> to_string() |> escape()
end
