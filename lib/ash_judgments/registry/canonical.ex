# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Canonical do
  @moduledoc """
  Canonical JSON and the digest pipeline of the judgment-record RFC
  (§4.2/§4.3): the exact computation `question_hash` hangs off.

  Canonical JSON is semantic-manifest §7.2 verbatim, plus the RFC's one
  explicit rule: every real number is a decimal string — the shortest
  decimal that round-trips the IEEE-754 double
  (`:erlang.float_to_binary(x, [:short])`), never a display rounding.
  Keys are sorted recursively, there is no whitespace, atoms are strings,
  `null` is explicit, arrays keep their order (declaration order for
  options is part of a question's identity).

  Digests are `"sha256:" <> 64 lower hex` — full 256 bits for every digest
  the RFC defines (Q4). The digest of nothing is `nil`, never the digest
  of `{}` (§4.2 rule 3): an undeclared projection contracts to `nil`.
  """

  @moduledoc since: "0.1.0"

  @type json ::
          nil | boolean() | integer() | float() | String.t() | [json()] | %{String.t() => json()}

  @doc """
  The canonical JSON encoding: sorted keys, no whitespace, atoms as
  strings, explicit `null`, arrays in order, real numbers as
  shortest-round-trip decimal strings.
  """
  @spec encode(json() | map() | keyword()) :: String.t()
  def encode(value), do: enc(value)

  @doc """
  `"sha256:" <> lower hex` (64 characters) over the canonical JSON.
  """
  @spec digest(json() | map() | keyword()) :: String.t()
  def digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, encode(value)) |> Base.encode16(case: :lower))
  end

  @doc """
  The `state_contract` digest (§3.2): the digest of the projection's
  declared output shape, or `nil` when no shape is declared — the digest
  of nothing is `nil`, never the digest of `%{}`.
  """
  @spec state_contract(term()) :: String.t() | nil
  def state_contract(nil), do: nil
  def state_contract(shape), do: digest(shape)

  @doc """
  The `question_hash` (§3.2): the digest of the canonical JSON of exactly
  the identity object — `answer_type`, `criteria`, `instructions`,
  `options` (declaration order), `state_contract` and `version`. Family
  and lineage are deliberately outside (§3.2/Q3): moving a question
  between families is a governance act, not a new question.

  `instructions` and `criteria` go in exactly as declared — the canonical
  rules normalise structure (sorted keys, no whitespace between tokens)
  but never string values, so a wording change (including whitespace
  inside the instructions) is a new question, per law 4.
  """
  @spec question_hash(%{
          required(:answer_type) => module(),
          required(:instructions) => term(),
          required(:options) => [term()],
          required(:state_contract) => String.t() | nil,
          required(:version) => pos_integer(),
          optional(:criteria) => term()
        }) :: String.t()
  def question_hash(%{} = declaration) do
    digest(%{
      "answer_type" => module_name(declaration.answer_type),
      "criteria" => Map.get(declaration, :criteria),
      "instructions" => declaration.instructions,
      "options" => Enum.map(declaration.options, &normalize_option/1),
      "state_contract" => declaration.state_contract,
      "version" => declaration.version
    })
  end

  @doc """
  The structural question id (§3.1): `judgment:v0:<Module>#judgments/<name>`
  — `<Module>` dotted, without the `Elixir.` prefix. It names the slot;
  the content lives in `question_hash`.
  """
  @spec question_id(module(), atom()) :: String.t()
  def question_id(resource, name) when is_atom(resource) and is_atom(name) do
    "judgment:v0:#{module_name(resource)}#judgments/#{name}"
  end

  defp normalize_option(option) when is_atom(option), do: Atom.to_string(option)
  defp normalize_option(option) when is_boolean(option), do: option
  defp normalize_option(option) when is_binary(option), do: option
  defp normalize_option(option), do: option

  defp module_name(module) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end

  ## The encoder. Jason is not used directly because map key order must be
  ## sorted and real numbers must be decimal strings — both are RFC rules
  ## the value domain makes cheap to implement exactly.

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"

  defp enc(value) when is_integer(value), do: Integer.to_string(value)

  defp enc(value) when is_float(value) do
    # §4.3: real numbers are DECIMAL STRINGS — the shortest decimal that
    # round-trips the double (the shortest round-trip of an integral double
    # still carries its ".0"; that is the honest rendering of what the
    # runtime returned).
    string(:erlang.float_to_binary(value, [:short]))
  end

  defp enc(value) when is_binary(value), do: string(value)

  defp enc(value) when is_atom(value), do: string(Atom.to_string(value))

  defp enc(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &enc/1) <> "]"

  defp enc(%Decimal{} = value) do
    # Decimal is already an exact decimal string in disguise (the RFC's
    # Postgres `numeric` rule); render it as its string.
    string(Decimal.to_string(value))
  end

  defp enc(%_{} = value) do
    enc(Map.from_struct(value))
  end

  defp enc(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {key(k), enc(v)} end)
    |> Enum.sort(&key_order/2)
    |> Enum.map_join(",", fn {k, v} -> string(k) <> ":" <> v end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp enc(value) when is_tuple(value), do: enc(Tuple.to_list(value))

  defp enc(value) do
    raise ArgumentError, "cannot canonicalise #{inspect(value)}"
  end

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_integer(k), do: Integer.to_string(k)

  defp key_order({a, _}, {b, _}), do: a <= b

  defp string(value) do
    [?", escape(String.graphemes(value), value), ?"] |> IO.iodata_to_binary()
  end

  @escapes %{
    "\"" => "\\\"",
    "\\" => "\\\\",
    "\n" => "\\n",
    "\r" => "\\r",
    "\t" => "\\t",
    "\b" => "\\b",
    "\f" => "\\f"
  }

  defp escape([grapheme | rest], original) do
    case Map.fetch(@escapes, grapheme) do
      {:ok, escaped} -> [escaped | escape(rest, original)]
      :error -> [grapheme | escape(rest, original)]
    end
  end

  defp escape([], _original), do: []
end
