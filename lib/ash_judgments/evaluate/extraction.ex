# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Evaluate.Extraction do
  @moduledoc """
  The extraction answer type (the extraction-answer-type design, §1):
  one question extracts one typed value, with a required status and the
  source atom ids that back it.

      %Extraction{status: :found | :not_found | :ambiguous,
                  value: term(),          # cast through the declared `of` type
                  source_ids: [String.t()]}  # atom ids only, never quotations (law 8)

  - **`status` is required on every answered extraction**; `value` is
    non-nil **iff** `status == :found`. `not_found` and `ambiguous`
    carry `value: nil` — a candidate reading on an ambiguous extraction
    is the raw reply's business, never an admissible value.
  - **No `confidence`, structurally**: the type has no such field, so
    the frozen `confidence: const null` conditional holds by
    construction, not by convention (ADR 0046 point 5).
  - A cast failure REJECTS — wrong status vocabulary, a value when none
    is allowed, a source id outside the packet's enum, an undecodable
    value: `from_answer/2` returns an error and upstream records
    `cast_failed` against the raw reply. Nothing is repaired.

  ## Constraints

  - `of:` — REQUIRED. The value's Ash type (e.g. `:string`, `:date`, an
    `Ash.Type.Enum` module), with `:constraints` for its inner
    constraints. The constraint that validates the value is the
    constraint sent on the wire (the `options_from` discipline).
  - `source_enum:` — the packet's atom ids as a list of strings. The
    declared form is `source_enum_from {Resource, :attribute}` on the
    registry question (resolved at compile time into this constraint);
    `nil` leaves source ids unvalidated (a packet-supplied enum arrives
    per question).

  ## Identity ([L]2)

  The declared value schema rides `criteria` (declared data, hashed
  verbatim — the frozen §3.2 hash object has no value-type slot); the
  registry's `options` for an extraction question are the status enum
  `["found", "not_found", "ambiguous"]`. Identity covers wording,
  status vocabulary and value type with zero record change.

  ## The wire output schema

  `output_schema/1` renders the narrowed output schema — hashed as
  `wire_schema_hash` (§5.3) by the caller:

      %{"value" => <schema from the declared type>,
        "status" => %{"enum" => ["found", "not_found", "ambiguous"]},
        "source_ids" => %{"type" => "array",
                          "items" => %{"type" => "string",
                                       "enum" => <the packet's atom ids>}}}

  No `confidence` key anywhere. The schema's value half is the ADR 0046
  one-mapping over common scalar Ash types; refinements that do not
  reach the schema (pattern, length bounds) ride the record, not the
  wire. Transport wiring (`json_schema` as a top-level call option) is
  a profile/`Wire` concern, not the type's.
  """

  defstruct [:status, :value, :source_ids]

  @type t :: %__MODULE__{
          status: :found | :not_found | :ambiguous,
          value: term(),
          source_ids: [String.t()]
        }

  @status_vocab [:found, :not_found, :ambiguous]

  use AshAi.Evaluate.Answer,
    constraints: [
      of: [
        type: :any,
        required: true,
        doc: "The value's Ash type — a scalar (`:string`, `:date`, …) or an `Ash.Type` module."
      ],
      constraints: [
        type: :keyword_list,
        default: [],
        doc: "Constraints for the `of` type, for example `one_of: [:a, :b]` or `match: ~r/…/`."
      ],
      source_enum: [
        type: {:list, :string},
        doc:
          "The packet's atom ids; source_ids outside it reject. Set from `source_enum_from` at compile time by the registry, or per question."
      ]
    ]

  @impl AshAi.Evaluate.Answer
  def answer_fields(constraints) do
    {:ok,
     [
       status: [type: :atom, constraints: [one_of: @status_vocab], allow_nil?: false],
       value: [
         type: Ash.Type.get_type(constraints[:of]),
         constraints: constraints[:constraints] || [],
         allow_nil?: true
       ],
       source_ids: [type: {:array, :string}, allow_nil?: false]
     ]}
  end

  @impl AshAi.Evaluate.Answer
  def to_question(instructions, criteria, constraints) do
    # [L]2: the declared value schema rides criteria — hashed verbatim in
    # the wire question and the question hash.
    criteria = criteria || value_schema(constraints)
    {:ok, %{type: :extraction, instructions: instructions, criteria: criteria}}
  end

  @impl AshAi.Evaluate.Answer
  def from_answer(answer, constraints)

  # Constraints arrive as a keyword list from the action path and a map
  # from direct calls — one shape for the plumbing below.
  def from_answer(
        %{"value" => value, "status" => status, "source_ids" => source_ids},
        constraints
      )
      when is_binary(status) and is_list(source_ids) and not is_map(constraints) do
    from_answer(
      %{"value" => value, "status" => status, "source_ids" => source_ids},
      Map.new(constraints)
    )
  end

  def from_answer(
        %{"value" => value, "status" => status, "source_ids" => source_ids},
        %{} = constraints
      )
      when is_binary(status) and is_list(source_ids) do
    with {:ok, status} <- cast_status(status),
         :ok <- check_value_presence(value, status),
         {:ok, value} <- cast_value(value, status, constraints),
         :ok <- check_source_ids(source_ids, constraints) do
      {:ok, %{status: status, value: value, source_ids: source_ids}}
    end
  end

  def from_answer(other, _constraints) do
    {:error, "expected an extraction answer (value, status, source_ids), got: #{inspect(other)}"}
  end

  @doc """
  The narrowed output schema (see the moduledoc): the declared value
  schema, the status enum, and source_ids constrained to the packet's
  atom ids. No `confidence` key anywhere.
  """
  @spec output_schema(keyword()) :: map()
  def output_schema(constraints) do
    %{
      "value" => value_schema(constraints),
      "status" => %{"enum" => Enum.map(@status_vocab, &Atom.to_string/1)},
      "source_ids" => %{
        "type" => "array",
        "items" => %{"type" => "string", "enum" => constraints[:source_enum] || []}
      }
    }
  end

  @doc "The status vocabulary, as atoms — the frozen §5.5 semantics."
  @spec statuses() :: [:found | :not_found | :ambiguous]
  def statuses, do: @status_vocab

  ## The value schema (ADR 0046's one mapping, over the common scalars)

  @scalar_schemas %{
    Ash.Type.String => %{"type" => "string"},
    Ash.Type.CiString => %{"type" => "string"},
    Ash.Type.Boolean => %{"type" => "boolean"},
    Ash.Type.Integer => %{"type" => "integer"},
    Ash.Type.Decimal => %{"type" => "string", "pattern" => "^-?[0-9]+(\\.[0-9]+)?$"},
    Ash.Type.Float => %{"type" => "number"},
    Ash.Type.Date => %{"type" => "string", "format" => "date"},
    Ash.Type.DateTime => %{"type" => "string", "format" => "date-time"},
    Ash.Type.Time => %{"type" => "string"},
    Ash.Type.Term => %{}
  }

  # Refinements (pattern, length bounds) do not reach the schema — they
  # ride the record (CLIN-34 finding 3, ADR 0046's known upstream gap).
  defp value_schema(constraints) do
    type = Ash.Type.get_type(constraints[:of])

    cond do
      schema = Map.get(@scalar_schemas, type) ->
        schema

      Spark.implements_behaviour?(type, Ash.Type.Enum) ->
        %{"type" => "string", "enum" => Enum.map(type.values(), &to_string/1)}

      type == Ash.Type.Atom and is_list(constraints[:constraints][:one_of]) ->
        %{
          "type" => "string",
          "enum" => Enum.map(constraints[:constraints][:one_of], &to_string/1)
        }

      type == Ash.Type.Map ->
        %{"type" => "object"}

      true ->
        # An unmapped type: the schema carries the declared type's name so
        # identity still pins it; the record pins the cast value either way.
        %{"type" => "string", "x-ash-type" => inspect(type)}
    end
  end

  ## from_answer plumbing — reject, never repair

  defp cast_status(status) do
    atom = String.to_existing_atom(status)

    if atom in @status_vocab do
      {:ok, atom}
    else
      {:error, "status is outside the vocabulary #{inspect(@status_vocab)}: #{inspect(status)}"}
    end
  rescue
    ArgumentError ->
      {:error, "status is outside the vocabulary #{inspect(@status_vocab)}: #{inspect(status)}"}
  end

  # value non-nil iff status == :found — enforced, not repaired.
  defp check_value_presence(nil, :found),
    do: {:error, "status is :found but the value is nil — a found extraction carries its value"}

  defp check_value_presence(value, status)
       when status in [:not_found, :ambiguous] and value != nil,
       do:
         {:error,
          "status is #{inspect(status)} but a value arrived — a non-found extraction carries no value (reject, never repair)"}

  defp check_value_presence(_value, _status), do: :ok

  defp cast_value(nil, _status, _constraints), do: {:ok, nil}

  defp cast_value(value, :found, constraints) do
    type = Ash.Type.get_type(constraints[:of])
    inner = constraints[:constraints] || []

    with {:ok, casted} <- Ash.Type.cast_input(type, value, inner),
         {:ok, constrained} <- Ash.Type.apply_constraints(type, casted, inner) do
      {:ok, constrained}
    else
      _ -> {:error, "value does not cast against the declared #{inspect(constraints[:of])}"}
    end
  end

  defp check_source_ids(source_ids, %{source_enum: enum}) when is_list(enum) and enum != [] do
    outside = Enum.reject(source_ids, &(&1 in enum))

    if outside == [] do
      :ok
    else
      {:error,
       "source ids outside the packet's enum: #{inspect(outside)} (the packet narrows to #{inspect(enum)})"}
    end
  end

  # No declared enum (or an empty one): source ids are unvalidated — the
  # packet's enum arrives per question on that path.
  defp check_source_ids(_source_ids, _constraints), do: :ok
end
