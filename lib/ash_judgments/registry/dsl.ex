# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Dsl do
  @moduledoc """
  The `judgments` section schema: one entity, `question`.

  Every option is data (law 4: the declaration is the shared schema).
  The identity fields the transformer derives — `question_hash`,
  `question_id`, `options`, `state_contract` — are struct fields, not
  schema options: hosts declare intent, the package derives identity.
  """

  @moduledoc since: "0.1.0"

  @answer_types [
    AshAi.Evaluate.Noul,
    AshAi.Evaluate.Choice,
    AshAi.Evaluate.Score,
    AshJudgments.Evaluate.Extraction
  ]

  @question_schema [
    name: [
      type: :atom,
      required: true,
      doc: "The question's name. Part of the structural id, not the content hash."
    ],
    type: [
      type: {:in, @answer_types},
      required: true,
      doc:
        "The answer type: `AshAi.Evaluate.Noul`, `AshAi.Evaluate.Choice`, `AshAi.Evaluate.Score` or `AshJudgments.Evaluate.Extraction` (the typed extraction: status + value + source ids). The `Evidence` type ships with UP-AI-EVIDENCE-TYPE."
    ],
    constraints: [
      type: :keyword_list,
      default: [],
      doc:
        "Answer-type constraints — for a Choice, `of:` (an `Ash.Type.Enum` module or an option list); for a Score, `levels:`; for an Extraction, `of:` (REQUIRED — the value's Ash type + inner `constraints:`) and `source_enum:` (an explicit atom-id list)."
    ],
    options_from: [
      type: {:tuple, [{:spark, Ash.Resource}, :atom]},
      doc:
        "`{Resource, :attribute}` — Choice options derived from that attribute's `one_of` or `Ash.Type.Enum` values at compile time (the same `one_of` that validates the attribute is the option list of the Choice)."
    ],
    source_enum_from: [
      type: {:tuple, [{:spark, Ash.Resource}, :atom]},
      doc:
        "`{Resource, :attribute}` — Extraction source_ids narrowed to that attribute's values at compile time (the packet's atom ids; `options_from`'s sibling). One of this or `constraints source_enum:` is REQUIRED for an Extraction."
    ],
    abstain_option: [
      type: :atom,
      default: :insufficient,
      doc:
        "Appended to a Choice's options as the first-class abstention (law 7). Ignored for Noul and Score."
    ],
    instructions: [
      type: :any,
      required: true,
      doc:
        "The question's wording: a string, or the declared JSON structure. Part of the hash exactly as declared — the canonical rules normalise structure, never string values."
    ],
    criteria: [
      type: :any,
      doc: "Per-option or true/false descriptions, as declared. Part of the hash."
    ],
    version: [
      type: :pos_integer,
      required: true,
      doc:
        "The question's version, monotonic per question id. A hash change without a version bump fails the lock check at compile time."
    ],
    family: [
      type: :atom,
      required: true,
      doc:
        "The calibration grouping (law 5). Outside the hash: moving a question between families is a governance act, not a new question."
    ],
    state_projection: [
      type: {:or, [:atom, {:tuple, [:atom, :atom]}]},
      doc:
        "A module implementing `project(input, context) :: map` (or an MFA). Minimises what the model sees (the `state:` seam)."
    ],
    state_shape: [
      type: :any,
      doc:
        "The DECLARED output shape of the state projection, as data — what `state_contract` hashes (RFC §3.2, Q1: the declared shape is part of identity; a refactor that does not alter the shape does not mint a new question). Undeclared, the contract is `nil` (the digest of nothing). When ADR 0046's single Ash-type mapping lands, this may be an Ash type + constraints instead of a literal map."
    ],
    pii: [
      type: {:in, [:none, :minimised]},
      default: :none,
      doc: "`:minimised` requires a `state_projection` (a verifier enforces it at compile time)."
    ],
    profile: [
      type: :any,
      required: true,
      doc:
        "The instrument: an `AshJudgments.Profile` registry name, or a resolver (an arity-2 function of `(input, context)` returning a model spec)."
    ],
    record: [
      type: {:in, [:must, :best_effort]},
      default: :must,
      doc:
        "ADR 0040 record policy: compliance families fail closed (`:must`); tooling may be `:best_effort`."
    ],
    ttl: [
      type: :pos_integer,
      doc:
        "Cache TTL in seconds for the question's family (CORE-CACHE consumes it). Absent means never reuse."
    ],
    pin: [
      type: {:in, [:required, :optional]},
      doc:
        "Defaults to `:required` when `record: :must` (law 6: floating aliases are forbidden in compliance paths); otherwise `:optional`."
    ],
    expose_as_tool?: [
      type: :boolean,
      default: false,
      doc:
        "Generates an ash_ai `tool` entry for the judge action, so agents can call the question over MCP. Read-only by construction."
    ],
    bpmn_callable?: [
      type: :boolean,
      default: false,
      doc:
        "Generates a `judge_<name>_signals` action returning a STRING-KEYED, SCALAR-VALUED map (the answer's scalars plus the judgment id) — the shape a BPMN `ash:call` may promote onto a token. Answer structs never promote (the scalar-promotion discipline, AST-94)."
    ]
  ]

  @question %Spark.Dsl.Entity{
    name: :question,
    describe: "Declares a System One question over this resource.",
    target: AshJudgments.Registry.Question,
    args: [:name],
    identifier: :name,
    schema: @question_schema,
    transform: {AshJudgments.Registry.Question, :build, []}
  }

  @judgments %Spark.Dsl.Section{
    name: :judgments,
    describe: """
    Declares System One questions over this resource.

    Each question is a declaration (law 4): typed by an upstream answer
    type, options drawn from constraints, versioned and content-hashed —
    the hash is the question's identity in the ledger. The section
    generates `judge_<name>` (and `judge_<name>_matrix`) actions and can
    expose the judge as a read-only agent tool.
    """,
    entities: [@question]
  }

  @doc """
  The `judgments` section, as data — the extension consumes this.
  """
  def sections, do: [@judgments]
end
