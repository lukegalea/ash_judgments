# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Evaluate.Evidence do
  @moduledoc """
  The evidence answer type (ticket AST-97, the evidence-outcome algebra):
  one question asks whether the state's evidence SUPPORTS, CONTRADICTS or
  is INSUFFICIENT for a predicate — the frozen §5.5 disposition, never an
  admission.

      %Evidence{value: :supports | :contradicts | :insufficient
                            | :not_applicable (| :wrong_scope),
                probabilities: %{disposition => float()},  # the distribution
                confidence: float(),                       # 0..1, as returned
                source_ids: [String.t()]}                  # atom ids only (law 8)

  - **The vocabulary is frozen** (§5.5, "Disposition is not admission"):
    `supports | contradicts | insufficient | not_applicable`, plus the
    OPTIONAL `wrong_scope` when the question declares
    `constraints wrong_scope: true`. Nothing else casts — a fifth,
    uninvited disposition is a cast failure recorded `cast_failed`
    against the raw reply (ADR 0046 point 3). No band, compliance or
    admission vocabulary leaks in here.
  - **A four-way `Choice`, specialised** (ADR 0039): the wire question is
    a `:choice` over exactly the declared outcome set, and the raw reply
    is the choice shape (`choice`/`probabilities`/`confidence`) — the
    type reads it and enforces the evidence vocabulary on `value` AND on
    the probability keys.
  - **`source_ids` carry the cited atoms** (§5.5 lists source_ids for
    extraction AND evidence): atom ids only, never quotations (law 8).
    With `source_enum:` declared, ids outside the packet reject — the
    extraction discipline; undeclared, ids are unvalidated (the CLIN-34
    per-call narrowing is an extraction contract, not this type's).
  - **`confidence` is 0..1 or rejected** — a confidence outside the unit
    interval is a broken instrument reply, not a number to clamp. Upstream's
    `Choice` passes confidence through unvalidated; this type does not
    repair.

  ## Constraints

  - `wrong_scope:` — default `false`. `true` extends the outcome set
    (and every derived options/schema list) with `:wrong_scope`.
  - `source_enum:` — the packet's atom ids as a list of strings;
    `source_ids` outside it reject.

  ## Identity ([L]2)

  The outcome vocabulary is frozen, so a question's identity `options`
  ARE the dispositions (as strings) — the same rule that makes an
  extraction's identity options the status enum. Caller-declared
  `criteria` (disposition descriptions) ride the hash verbatim.

  ## The wire output schema

  `output_schema/1` renders the narrowed output schema:

      %{"value" => %{"type" => "string", "enum" => [<the outcome set>]},
        "probabilities" => %{"type" => "object",
                             "propertyNames" => %{"enum" => [<the outcome set>]}},
        "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "source_ids" => %{"type" => "array",
                          "items" => %{"type" => "string",
                                       "enum" => <the packet's atom ids>}}}

  A cast failure REJECTS — wrong disposition vocabulary, an
  out-of-range confidence or probability, a source id outside the
  packet's enum: `from_answer/2` returns an error and upstream records
  `cast_failed` against the raw reply. Nothing is repaired.
  """

  defstruct [:value, :probabilities, :confidence, :source_ids]

  @type disposition :: :supports | :contradicts | :insufficient | :not_applicable | :wrong_scope

  @type t :: %__MODULE__{
          value: disposition(),
          probabilities: %{term() => float()},
          confidence: float(),
          source_ids: [String.t()]
        }

  @base_dispositions [:supports, :contradicts, :insufficient, :not_applicable]
  @wrong_scope :wrong_scope

  use AshAi.Evaluate.Answer,
    constraints: [
      wrong_scope: [
        type: :boolean,
        default: false,
        doc:
          "Whether the optional `wrong_scope` disposition is in the outcome set (§5.5: plus the optional wrong_scope, where declared)."
      ],
      source_enum: [
        type: {:list, :string},
        doc:
          "The packet's atom ids; source_ids outside it reject. Undeclared, source ids are unvalidated."
      ]
    ]

  @impl AshAi.Evaluate.Answer
  def answer_fields(constraints) do
    {:ok,
     [
       value: [type: :atom, constraints: [one_of: dispositions(constraints)], allow_nil?: false],
       probabilities: [type: :map, allow_nil?: false],
       confidence: [type: :float, allow_nil?: false],
       source_ids: [type: {:array, :string}, allow_nil?: false]
     ]}
  end

  @impl AshAi.Evaluate.Answer
  def to_question(instructions, criteria, constraints) do
    # [L]2: declared criteria ride verbatim; the frozen outcome set is the
    # default. The wire question is a :choice (ADR 0039 — evidence is the
    # four-way Choice, specialised, not a new wire kind).
    criteria = criteria || default_criteria(constraints)
    {:ok, %{type: :choice, instructions: instructions, criteria: criteria}}
  end

  @impl AshAi.Evaluate.Answer
  def from_answer(answer, constraints)

  # Constraints arrive as a keyword list from the action path and a map
  # from direct calls — one shape for the plumbing below.
  def from_answer(answer, constraints) when not is_map(constraints) do
    from_answer(answer, Map.new(constraints))
  end

  def from_answer(%{} = answer, %{} = constraints) do
    with {:ok, outcome} <- raw_outcome(answer),
         {:ok, value} <- cast_value(outcome, constraints),
         {:ok, probabilities} <- cast_probabilities(answer["probabilities"], constraints),
         {:ok, confidence} <- cast_confidence(answer["confidence"]),
         {:ok, source_ids} <- cast_source_ids(answer["source_ids"] || [], constraints) do
      {:ok,
       %{
         value: value,
         probabilities: probabilities,
         confidence: confidence,
         source_ids: source_ids
       }}
    end
  end

  def from_answer(other, _constraints) do
    {:error,
     "expected an evidence answer (choice, probabilities, confidence), got: #{inspect(other)}"}
  end

  @doc """
  The frozen disposition vocabulary (§5.5): the four-way outcome set,
  as atoms — the question's identity options.
  """
  @spec dispositions() :: [:supports | :contradicts | :insufficient | :not_applicable]
  def dispositions, do: @base_dispositions

  @doc """
  The outcome set for a question declaring `wrong_scope:` — the frozen
  four, plus `:wrong_scope` when declared. Accepts the constraints
  (keyword or map) or a bare boolean.
  """
  @spec dispositions(keyword() | map() | boolean()) :: [disposition()]
  def dispositions(constraints) when is_list(constraints),
    do: dispositions(Map.new(constraints))

  def dispositions(constraints) when is_map(constraints) do
    if constraints[:wrong_scope] in [true, "true"],
      do: @base_dispositions ++ [@wrong_scope],
      else: @base_dispositions
  end

  def dispositions(true), do: @base_dispositions ++ [@wrong_scope]
  def dispositions(false), do: @base_dispositions

  @doc """
  The narrowed output schema (see the moduledoc): the outcome enum on
  `value` AND on the probability keys, the unit-interval confidence, and
  source_ids narrowed to the packet's atom ids when declared.
  """
  @spec output_schema(keyword() | map()) :: map()
  def output_schema(constraints) when is_list(constraints),
    do: output_schema(Map.new(constraints))

  def output_schema(constraints) when is_map(constraints) do
    outcomes = Enum.map(dispositions(constraints), &Atom.to_string/1)

    %{
      "value" => %{"type" => "string", "enum" => outcomes},
      "probabilities" => %{"type" => "object", "propertyNames" => %{"enum" => outcomes}},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
      "source_ids" => %{
        "type" => "array",
        "items" => %{"type" => "string", "enum" => constraints[:source_enum] || []}
      }
    }
  end

  ## from_answer plumbing — reject, never repair

  # The raw reply is the choice shape (the wire question is a :choice);
  # `evidence` is the type's own key alias. One of them must be present.
  defp raw_outcome(%{"choice" => outcome}), do: {:ok, outcome}
  defp raw_outcome(%{"evidence" => outcome}), do: {:ok, outcome}

  defp raw_outcome(answer) do
    {:error,
     "an evidence answer names its outcome under `choice` (the wire shape) or `evidence`, got: #{inspect(answer)}"}
  end

  defp cast_value(outcome, constraints) when is_binary(outcome) do
    allowed = dispositions(constraints)

    atom = String.to_existing_atom(outcome)

    if atom in allowed do
      {:ok, atom}
    else
      {:error, "outcome is outside the vocabulary #{inspect(allowed)}: #{inspect(outcome)}"}
    end
  rescue
    ArgumentError ->
      {:error,
       "outcome is outside the vocabulary #{inspect(dispositions(constraints))}: #{inspect(outcome)}"}
  end

  defp cast_value(outcome, _constraints) do
    {:error, "the outcome must be a string naming a disposition, got: #{inspect(outcome)}"}
  end

  defp cast_probabilities(probabilities, constraints) when is_map(probabilities) do
    allowed = MapSet.new(dispositions(constraints))

    Enum.reduce_while(probabilities, {:ok, %{}}, fn
      {key, p}, {:ok, acc} when is_binary(key) ->
        cond do
          not key_disposition?(key, allowed) ->
            {:halt,
             {:error,
              "probability key is outside the vocabulary #{inspect(Enum.map(allowed, &to_string/1))}: #{inspect(key)}"}}

          not unit_interval?(p) ->
            {:halt,
             {:error, "probability for #{inspect(key)} is not a number in 0..1: #{inspect(p)}"}}

          true ->
            # STRING keys, deliberately: the disposition vocabulary is
            # frozen (no `of` type to cast through, unlike a Choice), the
            # recorded distribution is string-keyed decimal strings, and
            # the DMN bridge reads dispositions as strings. The struct's
            # shape equals the wire's shape.
            {:cont, {:ok, Map.put(acc, key, p / 1)}}
        end

      {key, _p}, {:ok, _acc} ->
        {:halt, {:error, "probability keys are disposition strings, got: #{inspect(key)}"}}
    end)
  end

  defp cast_probabilities(probabilities, _constraints) do
    {:error,
     "probabilities must be a map of disposition => number, got: #{inspect(probabilities)}"}
  end

  defp key_disposition?(key, allowed) do
    atom = String.to_existing_atom(key)
    MapSet.member?(allowed, atom)
  rescue
    ArgumentError -> false
  end

  # A confidence outside 0..1 is a broken instrument reply — reject,
  # never clamp.
  defp cast_confidence(confidence) when is_number(confidence) do
    if unit_interval?(confidence),
      do: {:ok, confidence / 1},
      else: {:error, confidence_error(confidence)}
  end

  defp cast_confidence(confidence), do: {:error, confidence_error(confidence)}

  defp confidence_error(confidence),
    do: "confidence is not a number in 0..1: #{inspect(confidence)}"

  defp unit_interval?(p), do: is_number(p) and p >= 0 and p <= 1

  defp cast_source_ids(source_ids, constraints) when is_list(source_ids) do
    case constraints[:source_enum] do
      enum when is_list(enum) and enum != [] ->
        outside = Enum.reject(source_ids, &(is_binary(&1) and &1 in enum))

        if outside == [] do
          {:ok, source_ids}
        else
          {:error,
           "source ids outside the packet's enum: #{inspect(outside)} (the packet narrows to #{inspect(enum)})"}
        end

      _ ->
        if Enum.all?(source_ids, &is_binary/1) do
          {:ok, source_ids}
        else
          {:error, "source ids are atom ids (strings) only, got: #{inspect(source_ids)}"}
        end
    end
  end

  defp cast_source_ids(source_ids, _constraints) do
    {:error, "source_ids must be a list of atom-id strings, got: #{inspect(source_ids)}"}
  end

  ## The default criteria: the outcome set with no per-disposition
  ## descriptions (the Choice criteria shape).

  defp default_criteria(constraints) do
    Map.new(Enum.map(dispositions(constraints), &Atom.to_string/1), &{&1, nil})
  end
end
