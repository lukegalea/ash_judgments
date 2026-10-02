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

  Conformal selective prediction renders as a two-band decision table
  over the conformal score (the flattened evidence-style input
  `p_supports`, override with `:score_input`):

  - `score >= λ̂` → `admit` (`reason_code` `conformal_threshold_met`);
  - `score < λ̂` → `review` (`reason_code` `below_conformal_threshold`).

  **There is no default rule** (ADR 0041): an input that is not a number
  — an absent or malformed score — matches no row, `matched_rule_ids`
  comes back empty, and that empty match is a REFUSAL, not a result. The
  `omit` band and any `fact_value` outputs are never invented here: this
  renderer emits exactly what the run earned (the threshold), and the
  frozen band enum's other outputs belong to the host's reviewed table.

  ## Structural validation

  The proposal is validated BEFORE rendering; a malformed proposal
  renders nothing:

  - a non-empty map;
  - `definition_key` — a non-empty string (the draft definition's name);
  - `family_tag` — the frozen `judgments:family:<F>` tag naming
    (§7.1's convention);
  - `thresholds` — a map whose `"threshold"` parses as a decimal in
    `[0, 1]` (the earned λ̂; nothing else in `thresholds` — a cost
    matrix, say — is rendered).

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

  - `:score_input` — the FEEL input name the threshold gates on
    (default `"p_supports"`, the flattened evidence-style score input).

  Returns `{:ok, xml}` or `{:error, findings}` — a non-empty list of
  human-readable findings. Never raises.
  """
  @spec render(term(), keyword()) :: {:ok, String.t()} | {:error, [String.t()]}
  def render(proposal, opts \\ [])

  def render(proposal, opts) when is_map(proposal) and not is_struct(proposal) do
    score_input = Keyword.get(opts, :score_input, "p_supports")

    findings =
      [key_finding(proposal), tag_finding(proposal), threshold_finding(proposal)]
      |> Enum.reject(&is_nil/1)

    if findings == [] do
      {:ok, document(proposal, score_input)}
    else
      {:error, findings}
    end
  end

  def render(_proposal, _opts) do
    {:error, ["the proposal must be a map of the recorded proposed_band_table shape"]}
  end

  ## Structural validation

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

    unless is_map(thresholds) do
      "the proposal needs a `thresholds` map carrying the earned threshold"
    else
      case decimal(fetch(thresholds, :threshold)) do
        {:ok, value} ->
          if Decimal.compare(value, Decimal.new(0)) == :lt or
               Decimal.compare(value, Decimal.new(1)) == :gt do
            "the threshold must be within [0, 1] (got: #{Decimal.to_string(value)})"
          else
            nil
          end

        :error ->
          "the `thresholds[\"threshold\"]` must parse as a decimal in [0, 1] " <>
            "(got: #{inspect(fetch(thresholds, :threshold))})"
      end
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

  defp document(proposal, score_input) do
    key = fetch(proposal, :definition_key)
    threshold = proposal |> fetch(:thresholds) |> fetch(:threshold)
    id = ncname(key)
    score = ncname(score_input)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 id="#{id}_definitions"
                 name="#{escape(key)}"
                 namespace="https://ash-judgments.test/#{id}"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      <inputData id="input_#{score}" name="#{escape(score_input)}">
        <variable id="var_#{score}" name="#{escape(score_input)}" typeRef="number"/>
      </inputData>
      <decision id="decision_#{id}" name="#{escape(key)}">
        <variable id="var_#{id}" name="#{escape(key)}" typeRef="string"/>
        <informationRequirement id="req_#{score}">
          <requiredInput href="#input_#{score}"/>
        </informationRequirement>
        <decisionTable id="table_#{id}" hitPolicy="UNIQUE" outputLabel="band">
          <input id="clause_#{score}" label="Conformal score">
            <inputExpression id="expr_#{score}" typeRef="number">
              <text>#{escape(score_input)}</text>
            </inputExpression>
          </input>
          <output id="clause_band" name="band" label="band" typeRef="string"/>
          <output id="clause_reason_code" name="reason_code" label="reason_code" typeRef="string"/>
          <rule id="rule_admit">
            <inputEntry id="rule_admit_0"><text>&gt;= #{escape(threshold)}</text></inputEntry>
            <outputEntry id="rule_admit_1"><text>"admit"</text></outputEntry>
            <outputEntry id="rule_admit_2"><text>"conformal_threshold_met"</text></outputEntry>
          </rule>
          <rule id="rule_review">
            <inputEntry id="rule_review_0"><text>&lt; #{escape(threshold)}</text></inputEntry>
            <outputEntry id="rule_review_1"><text>"review"</text></outputEntry>
            <outputEntry id="rule_review_2"><text>"below_conformal_threshold"</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
    </definitions>
    """
    |> String.trim_trailing("\n")
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
