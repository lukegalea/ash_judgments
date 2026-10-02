# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Bpmn do
  @moduledoc """
  The BPMN bridge — **ticket AST-94** (CORE-BRIDGE-BPMN).

  The `ash:call` service task binds to a domain callables allowlist and runs
  through `Ash.run_action`, so an evaluate action can be a callable with no
  engine change. But answer structs cannot be promoted onto a token —
  promoted signals must be flat scalars — so this bridge generates
  `judge_<name>_signals` callables for questions declaring
  `bpmn_callable? true`, returning string-keyed, scalar-valued maps
  (`"<q>_p"`, `"<q>_value"`, `"<q>_confidence"`, `"<q>_judgment_id"`). The
  token carries promoted scalars; the ledger row is the full record.

  ## Scope (AST-94)

  - Generated signal callables and the documented `promote` snippet for the
    BPMN XML.
  - An example standing-evaluation process fixture (timer/message start →
    judge-signals call → band-table business rule task → gateway on band →
    human review lane → end).
  - An integration test running the fixture through the `ash_bpmn`
    interpreter in the test support app.

  Requires the optional `ash_bpmn` dependency. TODO(AST-94): the feature
  logic; this stub carries only the availability contract.
  """

  @doc """
  Shapes a judged answer into the STRING-KEYED, SCALAR-VALUED signals map
  a BPMN token may carry: `<q>__judgment_id` (the token's join back to
  the full ledger row), plus the answer's scalars - `<q>__p` for a Noul,
  `<q>__value` + `<q>__confidence` for a Choice, `<q>__position` +
  `<q>__level` for a Score. No answer struct, no map-of-structs, no
  dotted paths - the token promotion hazard is the whole point of this
  shape.
  """
  def signal_map(question_key, question, answer, judgment_id) do
    base = %{(question_key <> "__judgment_id") => judgment_id}

    case answer_kind(question) do
      :noul ->
        Map.put(base, question_key <> "__p", decimal_string(probability_of(answer)))

      :choice ->
        base
        |> Map.put(question_key <> "__value", to_string(value_of(answer)))
        |> Map.put(question_key <> "__confidence", decimal_string(confidence_of(answer)))

      :score ->
        base
        |> Map.put(question_key <> "__position", decimal_string(position_of(answer)))
        |> Map.put(question_key <> "__level", to_string(level_of(answer)))

      :evidence ->
        base
        |> Map.put(question_key <> "__value", to_string(value_of(answer)))
        |> Map.put(question_key <> "__confidence", decimal_string(confidence_of(answer)))

      _kind ->
        base
    end
  end

  @doc """
  `:ok` when the `ash_bpmn` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_bpmn}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_bpmn}}
  def available? do
    AshJudgments.Availability.ensure(:ash_bpmn)
  end

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

  defp level_of(answer) when is_struct(answer), do: Map.get(answer, :level)
  defp level_of(answer) when is_map(answer), do: Map.get(answer, :level)
  defp level_of(_), do: nil

  defp confidence_of(answer) when is_struct(answer), do: Map.get(answer, :confidence)
  defp confidence_of(answer) when is_map(answer), do: Map.get(answer, :confidence)
  defp confidence_of(_), do: nil

  defp position_of(answer) when is_struct(answer), do: Map.get(answer, :value)
  defp position_of(answer) when is_map(answer), do: Map.get(answer, :value)
  defp position_of(_), do: nil

  defp decimal_string(nil), do: nil

  defp decimal_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value)
  defp decimal_string(value) when is_binary(value), do: value
end
