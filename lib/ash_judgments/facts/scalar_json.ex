# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.ScalarJson do
  @moduledoc """
  The facts table's value type: any JSON-encodable term — SCALARS first
  ([L]1): `true`, `"urgent"`, `80`. Wrapper maps only for genuinely
  composite values (extraction structs), where the bridge declares the
  schema entry `:map`.

  Storage is jsonb, so the data layer's equality on this column is a
  **superset** of the set evaluator's strict equality: jsonb compares
  `80` and `80.0` as equal (numeric), while `AshRules.Ir.values_equal?/2`
  does not — the evaluator narrows with the filter and re-verifies each
  candidate strictly (S1-54). Scalar probes therefore hit the index
  directly instead of being lost to a wrapper-map encoding.
  """

  @moduledoc since: "0.1.0"

  use Ash.Type.NewType, subtype_of: :string

  # The term is stored as its CANONICAL JSON text (§4.3 discipline:
  # sorted keys for maps/objects, decimal strings, shortest round-trip
  # for floats). Deterministic encoding keeps the column's text equality
  # exactly equal to term equality, so the set evaluator's data-layer
  # filter is neither a superset nor a subset — it is the strict check.
  def cast_input(value, _constraints) do
    case encode(value) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "value must be JSON-encodable"}
    end
  end

  # Loaded rows decode back to the term the materialiser wrote, so the
  # set evaluator's strict values_equal?/2 compares real values.
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(text, _constraints) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, text}
    end
  end

  def cast_stored(value, _constraints), do: {:ok, value}

  defp encode(value) when is_binary(value), do: {:ok, Jason.encode!(value)}
  defp encode(value) when is_boolean(value), do: {:ok, Atom.to_string(value)}
  defp encode(value) when is_integer(value), do: {:ok, Integer.to_string(value)}

  defp encode(value) when is_float(value),
    do: {:ok, :erlang.float_to_binary(value, [:short])}

  defp encode(value) when is_map(value) or is_list(value) do
    {:ok, AshJudgments.Registry.Canonical.encode(value)}
  end

  defp encode(_), do: :error
end
