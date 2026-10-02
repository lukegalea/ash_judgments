# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Dmn do
  @moduledoc """
  The DMN bridge — **ticket AST-92** (CORE-BRIDGE-DMN).

  Answers are DMN inputs, never FEEL functions. A model call inside FEEL
  would break the content-hashed, TCK-verified contract, blow the
  evaluator timeouts, and make matched-rule ids non-reproducible. So this
  bridge only FLATTENS recorded answers into a FEEL-ready context
  (decimal strings per §4.3) and defines the banding record + output
  contract; the evaluation itself goes through the host resolver seam
  (`band_table_ref/2`) into `ash_decisions` — nothing evaluates in this
  package, and band tables stay `ash_decisions` resources (ADR 0041).

  ## Flattening per answer kind (the placement doc's table)

  | Kind | FEEL inputs |
  |---|---|
  | noul | `p_true`, `p_false` (the two-way distribution) |
  | choice | `p_<option>` per option in declaration order, `value`, `confidence` |
  | score | `p_<level>` per level, `position`, `level` |
  | evidence | `p_supports`, `p_contradicts`, `p_insufficient`, `p_not_applicable` (+ `p_wrong_scope` where declared), `confidence` |
  | extraction | NO probabilities, NO confidence (ADR 0046 point 5); extract→verify pairs pass BOTH observation ids + the verification's `status` |

  All probabilities are decimal strings (§4.3). Missing/abstained/
  replay-missed answers are explicit `"present" => false` markers, never
  absent keys. Common envelope inputs on every table: `family`, risk
  tier, `jurisdiction`.

  ## The band contract (§7.1, frozen)

  Band-table outputs: `band` ∈ `admit | review | omit` (the frozen enum —
  Q11 settled `omitted` for admissions and `omit` for bandings; "unknown"
  is the ash_rules outcome layer, not this one), an optional `fact_value`
  on `admit`, and a `reason_code`. **`matched_rule_ids` empty is a
  refusal, not a result** (ADR 0041): a band table that cannot say which
  row fired is not auditable.

  Requires the optional `ash_decisions` dependency for the evaluation
  seam helpers; the pure flattening is dependency-free. Degraded
  (absent dep) evaluation-seam calls return
  `{:error, {:missing_dependency, :ash_decisions}}` and never raise.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Registry.Canonical

  @frozen_bands [:admit, :review, :omit]

  @doc "The frozen band enum (§7.1). Changing it is a frozen-record change."
  @spec bands() :: [:admit | :review | :omit]
  def bands, do: @frozen_bands

  @doc """
  `:ok` when the `ash_decisions` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_decisions}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_decisions}}
  def available? do
    AshJudgments.Availability.ensure(:ash_decisions)
  end

  @doc """
  Flattens recorded answers into the FEEL-ready input map.

  `answers` is a list of maps, each carrying:

  - `:question` — the registry question (declares type, options, levels);
  - `:answer` — the cast answer (upstream `Noul | Choice | Score` struct
    or its plain map), or `nil` when the answer is missing, abstained or
    a replay miss;
  - `:observation_id` — the observation's id;
  - optionally `:status` — the verification status for extract→verify
    pairs (`:found | :not_found | :ambiguous`);
  - optionally `:paired_with` — the OTHER observation id of the pair.

  `opts` carries the common envelope inputs: `:family` (string),
  `:risk_tier`, `:jurisdiction`. Inputs are keyed by the question's name
  and carry a `"present" => false` marker per answer when missing —
  absent keys are never sent (a FEEL table cannot distinguish an absent
  input from a falsy one).

  All probabilities are decimal strings (§4.3): shortest round-trip of
  the double, never a display rounding.
  """
  @spec inputs([map()], keyword()) :: map()
  def inputs(answers, opts \\ []) when is_list(answers) do
    flattened =
      Enum.reduce(answers, %{}, fn answer_map, acc ->
        Map.merge(acc, flatten_answer(answer_map))
      end)

    Map.merge(flattened, %{
      "family" => to_string(Keyword.get(opts, :family, "")),
      "risk_tier" => to_string(Keyword.get(opts, :risk_tier, "")),
      "jurisdiction" => to_string(Keyword.get(opts, :jurisdiction, ""))
    })
  end

  defp flatten_answer(%{question: question} = answer_map) do
    key = input_key(question)
    answer = Map.get(answer_map, :answer)

    base = %{
      "#{key}__present" => "true",
      "#{key}__observation_id" => Map.get(answer_map, :observation_id)
    }

    if answer == nil do
      # Explicit marker, never an absent key: a FEEL table cannot
      # distinguish an absent input from a falsy one.
      Map.put(base, "#{key}__present", "false")
    else
      case answer_kind(question) do
        :noul -> Map.merge(base, flatten_noul(answer, key))
        :choice -> Map.merge(base, flatten_choice(answer, question, key))
        :score -> Map.merge(base, flatten_score(answer, question, key))
        :evidence -> flatten_evidence(answer, key)
        :extraction -> flatten_extraction(answer_map, answer, key, base)
      end
    end
  end

  ## Per-kind flattening. All probabilities decimal strings (§4.3).

  defp flatten_noul(answer, key) do
    p = decimal_string(probability_of(answer))

    %{
      "#{key}__p_true" => p,
      "#{key}__p_false" => decimal_string(1 - parse_float(p))
    }
  end

  defp flatten_choice(answer, question, key) do
    probabilities = probabilities_of(answer)

    option_inputs =
      (declared_options(question) ++ Map.keys(probabilities))
      |> Enum.uniq()
      |> Map.new(fn option ->
        {"#{key}__p_#{option}", decimal_string(Map.get(probabilities, option))}
      end)

    option_inputs
    |> Map.merge(%{
      "#{key}__value" => to_string(value_of(answer)),
      "#{key}__confidence" => decimal_string(confidence_of(answer))
    })
  end

  defp flatten_score(answer, question, key) do
    probabilities = probabilities_of(answer)
    levels = levels_of(question)

    indexes = Enum.map(Enum.with_index(levels), fn {_level, i} -> Integer.to_string(i) end)

    level_inputs =
      (indexes ++ Map.keys(probabilities))
      |> Enum.uniq()
      |> Map.new(fn index ->
        {"#{key}__p_#{index}", decimal_string(Map.get(probabilities, index))}
      end)

    level_name =
      case value_of(answer) do
        %{} = answer_map -> Map.get(answer_map, :level) || Map.get(answer_map, "level")
        _ -> Map.get(answer, :level)
      end

    level_inputs
    |> Map.merge(%{
      "#{key}__position" => decimal_string(Map.get(answer, :value) || value_of(answer)),
      "#{key}__level" => to_string(level_name)
    })
  end

  defp flatten_evidence(answer, key) do
    probabilities = probabilities_of(answer)

    supported = ["supports", "contradicts", "insufficient", "not_applicable"]

    base_inputs =
      Map.new(supported, fn disposition ->
        {"#{key}__p_#{disposition}", decimal_string(Map.get(probabilities, disposition))}
      end)

    base_inputs
    |> Map.merge(wrong_scope_inputs(answer, key))
    |> Map.merge(%{"#{key}__confidence" => decimal_string(confidence_of(answer))})
  end

  defp wrong_scope_inputs(answer, key) do
    probabilities = probabilities_of(answer)

    if Map.has_key?(probabilities, :wrong_scope) or Map.has_key?(probabilities, "wrong_scope") do
      %{"#{key}__p_wrong_scope" => decimal_string(Map.get(probabilities, :wrong_scope))}
    else
      %{}
    end
  end

  defp flatten_extraction(answer_map, answer, key, base) do
    # ADR 0046 point 5: an extraction carries no probabilities and no
    # confidence. Extract→verify pairs pass BOTH observation ids — and
    # `__status` is the EXTRACTION'S OWN status, read from the answer
    # ([L]3): the verification is its own question and rides its own key.
    extraction = %{
      "#{key}__value" => Jason.encode!(value_of(answer)),
      "#{key}__observation_id_verified" =>
        Map.get(answer_map, :paired_with) || Map.get(answer_map, :observation_id)
    }

    extraction =
      case status_of(answer) do
        nil -> extraction
        status -> Map.put(extraction, "#{key}__status", to_string(status))
      end

    Map.merge(base, extraction)
  end

  ## Answer field access — upstream casts to structs but plain maps ride
  ## the same path (the fake/capture seam).

  defp answer_kind(question) do
    question.type
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_existing_atom()
  end

  defp probability_of(answer) when is_struct(answer), do: Map.get(answer, :probability)
  defp probability_of(answer) when is_map(answer), do: Map.get(answer, :probability)
  defp probability_of(_), do: nil

  defp value_of(answer) when is_struct(answer), do: Map.get(answer, :value)
  defp value_of(answer) when is_map(answer), do: Map.get(answer, :value)
  defp value_of(_), do: nil

  defp probabilities_of(answer) when is_struct(answer), do: Map.get(answer, :probabilities) || %{}
  defp probabilities_of(answer) when is_map(answer), do: Map.get(answer, :probabilities) || %{}
  defp probabilities_of(_), do: %{}

  defp confidence_of(answer) when is_struct(answer), do: Map.get(answer, :confidence)
  defp confidence_of(answer) when is_map(answer), do: Map.get(answer, :confidence)
  defp confidence_of(_), do: nil

  defp status_of(answer) when is_struct(answer), do: Map.get(answer, :status)
  defp status_of(answer) when is_map(answer), do: Map.get(answer, :status)
  defp status_of(_), do: nil

  defp declared_options(question) do
    case question.constraints[:of] do
      options when is_list(options) -> Enum.map(options, &to_string/1)
      module when is_atom(module) and module != nil -> declared_enum_options(module)
      _ -> []
    end
  end

  defp declared_enum_options(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :values, 0) do
      Enum.map(module.values(), &to_string/1)
    else
      []
    end
  end

  defp levels_of(question), do: question.constraints[:levels] || []

  defp decimal_string(nil), do: nil

  defp decimal_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value)
  defp decimal_string(value) when is_binary(value), do: value

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(value) when is_number(value), do: value * 1.0
  defp parse_float(_), do: 0.0

  defp input_key(question), do: to_string(question.name)

  ## The band contract + evaluation seam

  @doc """
  The band-table OUTPUT contract (§7.1), as data — for the host's band
  tables, the banding fragment's validation, and the docs:

  - `band` — the frozen enum `:admit | :review | :omit` (required);
  - `fact_value` — the fact value the table proposes, **admit only**;
  - `reason_code` — optional.

  **`matched_rule_ids` empty is a refusal, not a result** (ADR 0041): a
  band table that cannot say which row fired is not auditable.
  `validate_output/1` enforces the contract for the host's banding step.
  """
  @spec band_contract() :: map()
  def band_contract do
    %{
      outputs: %{
        "band" => %{
          type: :enum,
          values: Enum.map(@frozen_bands, &Atom.to_string/1),
          required: true
        },
        "fact_value" => %{type: :json, required: false, note: "admit only"},
        "reason_code" => %{type: :string, required: false}
      },
      refusal: %{
        rule: "matched_rule_ids empty is a refusal, not a result",
        check: &__MODULE__.refusal?/1
      },
      naming: %{
        convention: "the band table for family F is tagged `judgments:family:<F>`",
        note: "the banding fragment's verifier reads the tag through the host resolver"
      }
    }
  end

  @doc """
  Validates a band-table output against the contract (§7.1). Returns
  `:ok` or `{:error, message}` — the host's banding step refuses on
  error BEFORE any banding row is written.
  """
  @spec validate_output(map()) :: :ok | {:error, String.t()}
  def validate_output(output) when is_map(output) do
    band = output[:band] || output["band"]

    cond do
      band == nil ->
        {:error, "band output missing `band`"}

      band not in @frozen_bands ->
        {:error, "band #{inspect(band)} is not in the frozen enum #{inspect(@frozen_bands)}"}

      fact_value_on_non_admit?(band, output) ->
        {:error, "fact_value is admit-only; band #{inspect(band)} cannot propose a fact value"}

      true ->
        :ok
    end
  end

  defp fact_value_on_non_admit?(band, output) do
    band != :admit and
      ((output[:fact_value] != nil and output[:fact_value] != false) or
         (output["fact_value"] != nil and output["fact_value"] != false))
  end

  @doc """
  Whether a band-table evaluation is a REFUSAL: `matched_rule_ids` empty
  is a refusal, not a result (ADR 0041) — a band table that cannot say
  which row fired is not auditable.
  """
  @spec refusal?(map()) :: boolean()
  def refusal?(evaluation) when is_map(evaluation) do
    matched = evaluation[:matched_rule_ids] || evaluation["matched_rule_ids"]
    is_list(matched) and matched == []
  end

  @doc """
  Resolves the band-table reference for `(family, tenant)` through the
  host resolver seam — an MFA (`{m, f, a}`) passed in opts; the package
  never resolves a band table itself (ADR 0041: tenant-aware resolution
  of which versioned thing runs is host-side, the `Process.Resolver`
  pattern). The optional `ash_decisions` dependency must be present —
  degraded calls return the structured missing-dependency error.

  Returns `{:ok, band_table_ref}` where the ref is the host resolver's
  `{definition_key, definition_version, content_hash, definition_id,
  tenant_fork}` map (§7.1 `band_table`), or an error.
  """
  @spec band_table_ref(atom() | String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def band_table_ref(family, tenant, opts) do
    with :ok <- AshJudgments.Availability.ensure(:ash_decisions) do
      case opts[:resolver] do
        nil ->
          {:error,
           ArgumentError.exception(
             "no band-table resolver configured; pass resolver: {m, f, a} — " <>
               "tenant-aware resolution of which versioned band table runs is host-side (ADR 0041)"
           )}

        {m, f, a} ->
          apply(m, f, [family, tenant | a])

        resolver when is_function(resolver, 2) ->
          resolver.(family, tenant)

        _other ->
          {:error,
           ArgumentError.exception(
             "the band-table resolver must be an MFA or an arity-2 function"
           )}
      end
    end
  end

  @doc """
  The canonical JSON of a §7.1 `band_table` ref — what the banding
  fragment stores alongside the ids. Pure; no resolver call.
  """
  @spec band_table_canonical(map()) :: String.t()
  def band_table_canonical(band_table) when is_map(band_table) do
    Canonical.encode(band_table)
  end
end
