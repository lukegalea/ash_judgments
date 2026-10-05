# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Exploration do
  @moduledoc """
  The explore tier — labelled ordering by observation and exploratory
  questions (S1-56, design §1 and §4; ADR 0048).

  Three surfaces, one posture: **exploration never decides membership**.

  - `AshJudgments.Exploration.Ordering` — the read path that decorates a
    candidate set with the latest live answered observation per (question,
    subject), on explicit request, with the answered-by chip. A set
    expression first, an ordering spec second; ordering is decoration of a
    set, never a definition of one.
  - `AshJudgments.Exploration.Run.run/4` — the EXPLICIT bounded
    exploratory question run over the person's current candidate set.
    Never a trigger, never background, never in a read path.
  - `AshJudgments.Exploration.Recurrence` — deterministic recurrence
    detection over the wire-question hash, and the person-promote action
    that mints a question proposal. The detector only proposes: it never
    edits code, never activates, never widens a filter.

  ## The exploratory namespace ([L]1)

  Declared questions are slot-identified (`judgment:v0:<Module>#judgments/
  <name>`); exploratory questions are CONTENT-identified — the reserved
  namespace is `judgment:v0:<Module>#judgments/exploratory` and the hash of
  the ad-hoc identity object, not the slot, is the identity. Consumers
  treat the id as opaque-but-groupable.

  ## The family widening (design errata [L]2, §7.4 normative 5)

  §5.2 of the RFC marks `family` required while the folded §7.5 normative 5
  says exploratory observations have no family — the fold governs (the
  explore-tier design's errata note). This package implements the fold:
  the ledger fragment's `family` is nullable, and a validation ties null
  to the exploratory namespace exactly (`exploratory ⇔ family IS NULL`).
  Exploratory rows are never banded, never admitted, never fact-fed; they
  reach calibration only through person labelling (§7.3 `basis: "labelling"`).

  ## Envelope discipline

  Person-written instructions are payload-class and never persisted by this
  package (the identity object travels as its digest); digests and counts
  are envelope-class; aggregates carry counts, never actor ids.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Registry.Canonical

  @default_subjects 100
  @hard_cap 500
  @default_threshold 3
  @default_sample_size 25
  @exploratory_suffix "#judgments/exploratory"
  @detector "AshJudgments.Exploration.Recurrence"
  @detector_version "1"

  @type identity :: %{
          required(:answer_type) => module(),
          required(:instructions) => term(),
          required(:options) => [term()],
          required(:state_contract) => String.t() | nil,
          required(:version) => pos_integer(),
          optional(:criteria) => term()
        }

  @doc """
  The reserved exploratory namespace id for `module` ([L]1):
  `judgment:v0:<Module>#judgments/exploratory`. Content-addressed — the
  `question_hash` of the ad-hoc identity object is the identity; the slot
  is shared by every exploratory question on the resource and groups them,
  it never names one.
  """
  @spec question_id(module()) :: String.t()
  def question_id(module) when is_atom(module) do
    AshJudgments.Registry.Canonical.question_id(module, :exploratory)
  end

  @doc "Whether `question_id` is in the reserved exploratory namespace."
  @spec exploratory?(term()) :: boolean()
  def exploratory?(question_id)
      when is_binary(question_id),
      do: String.ends_with?(question_id, @exploratory_suffix)

  def exploratory?(_), do: false

  @doc "The default exploratory run bound: 100 subjects (`[L]4`)."
  @spec default_subjects() :: pos_integer()
  def default_subjects, do: @default_subjects

  @doc "The hard cap on an exploratory run: 500 subjects (`[L]4`)."
  @spec hard_cap() :: pos_integer()
  def hard_cap, do: @hard_cap

  @doc "The recurrence threshold K: 3 distinct invocations (`[L]4`)."
  @spec threshold() :: pos_integer()
  def threshold, do: @default_threshold

  @doc "The default subject-id sample size carried on a minted proposal."
  @spec default_sample_size() :: pos_integer()
  def default_sample_size, do: @default_sample_size

  @doc """
  The proposal metadata block: the detector and its version (`[L]3` —
  the detector rides in metadata, never in the proposer slot) and the
  threshold K at mint time.
  """
  @spec detector_metadata(pos_integer()) :: %{
          String.t() => String.t() | pos_integer()
        }
  def detector_metadata(k \\ @default_threshold) do
    %{
      "detector" => @detector,
      "detector_version" => @detector_version,
      "threshold_k" => k
    }
  end

  @doc """
  The §3.2 identity object of an ad-hoc question, exactly as run: answer
  type, criteria, instructions, options, `state_contract` when a projection
  was picked (`state_shape` given, hashed as the contract), `version: 1`.

  Options are derived from the answer type when not given (Noul
  `[true, false]`; Score its `constraints levels:`; Choice its `of` enum or
  list with the abstain option appended) — the same constraint the registry
  transformer applies to declared questions.
  """
  @spec identity(map()) :: identity()
  def identity(%{} = question) do
    %{
      answer_type: Map.fetch!(question, :type),
      criteria: Map.get(question, :criteria),
      instructions: Map.fetch!(question, :instructions),
      options: derive_options(question),
      state_contract:
        Map.get_lazy(question, :state_contract, fn ->
          Canonical.state_contract(Map.get(question, :state_shape))
        end),
      version: 1
    }
  end

  @doc "The digest of `AshJudgments.Exploration.identity/1` — the identity."
  @spec identity_hash(map()) :: String.t()
  def identity_hash(%{} = question) do
    question |> identity() |> Canonical.question_hash()
  end

  defp derive_options(question) do
    case Map.get(question, :options) || options_from_type(question) do
      [_ | _] = options -> options
      _ -> raise ArgumentError, "the ad-hoc question carries no options and none can be derived"
    end
  end

  defp options_from_type(%{type: AshAi.Evaluate.Noul}), do: [true, false]

  defp options_from_type(%{type: AshJudgments.Evaluate.Extraction}),
    do: Enum.map(AshJudgments.Evaluate.Extraction.statuses(), &Atom.to_string/1)

  defp options_from_type(%{type: AshAi.Evaluate.Score} = question) do
    levels =
      get_in(question, [:constraints, :levels]) || get_in(question, ["constraints", "levels"])

    levels ||
      raise ArgumentError,
            "an exploratory Score question needs `constraints levels:` (the ordered level list)"
  end

  defp options_from_type(%{type: AshAi.Evaluate.Choice} = question) do
    of = get_in(question, [:constraints, :of]) || get_in(question, ["constraints", "of"])

    of ||
      raise ArgumentError,
            "an exploratory Choice question needs `constraints of:` (an Ash.Type.Enum or an option list)"

    enum_options(of) ++ [Map.get(question, :abstain_option, :insufficient)]
  end

  defp options_from_type(_), do: nil

  defp enum_options(of) when is_atom(of) do
    cond do
      function_exported?(of, :values, 0) -> of.values()
      true -> raise ArgumentError, "#{inspect(of)} is not an Ash.Type.Enum"
    end
  end

  defp enum_options(of) when is_list(of), do: of

  ## Errors. Splode errors so they pass the Ash action boundary intact,
  ## like the cache's ReplayMiss/PinMismatch.

  defmodule UnknownQuestion do
    @moduledoc """
    The ordering spec names a `question_id` that is not DECLARED on the
    resource (design §1.3). Unrecognised ids are validation errors, never
    silent skips. Exploratory questions cannot order: they decorate the
    ordered tier as labelled chips, never as the sort key.
    """

    use Splode.Error, fields: [:question_id, :resource], class: :invalid

    def message(%{question_id: question_id, resource: resource}) do
      "ordering question #{inspect(question_id)} is not declared on #{inspect(resource)} — " <>
        "ordering resolves against the compile-time registry (design §1.3), and an " <>
        "exploratory question never orders (it decorates)"
    end
  end

  defmodule UnknownSelector do
    @moduledoc """
    The ordering spec's `selector` is not one of the question's derived
    options (design §1.3 — the same constraint that validates the attribute
    is the option list of the question).
    """

    use Splode.Error, fields: [:selector, :options, :question_id], class: :invalid

    def message(%{selector: selector, options: options, question_id: question_id}) do
      "ordering selector #{inspect(selector)} is not an option of #{question_id} " <>
        "(options: #{inspect(options)})"
    end
  end

  defmodule ScoreOnlyOrdering do
    @moduledoc """
    A request that orders by score without naming its set expression is
    refused (design §1.2): it would make ranking into existence (thesis 8).
    Order by a NAMED selector — an option or a level — over a candidate set
    the caller already holds; the score magnitude itself never orders.
    """

    use Splode.Error, fields: [:selector, :question_id], class: :invalid

    def message(%{selector: selector, question_id: question_id}) do
      "score-only ordering refused for #{question_id}: selector #{inspect(selector)} names the " <>
        "score itself, not an option or level — a set expression first, ordering second (design §1.2)"
    end
  end

  defmodule BoundExceeded do
    @moduledoc """
    An exploratory run over more than the hard cap of subjects (`[L]4`:
    default 100, hard cap 500) — refused, never silently truncated.
    """

    use Splode.Error, fields: [:given, :cap], class: :invalid

    def message(%{given: given, cap: cap}) do
      "exploratory run over #{given} subjects exceeds the hard cap of #{cap} " <>
        "— exploration is explicitly bounded (design §4.1, [L]4)"
    end
  end

  defmodule AlreadyProposed do
    @moduledoc """
    A question proposal already exists for this wire-question hash — the
    detector proposes once; further recurrence accumulates on the existing
    proposal's evidence, it never mints a second one.
    """

    use Splode.Error, fields: [:wire_question_hash], class: :invalid

    def message(%{wire_question_hash: wire_question_hash}) do
      "a question proposal already exists for wire hash #{wire_question_hash} — " <>
        "the detector proposes once (design §4.5)"
    end
  end

  defmodule ExploratoryRefused do
    @moduledoc """
    A governance path refused an exploratory observation: banding, admission
    and the fact materialiser all refuse rows from the exploratory namespace.
    They reach calibration only through person labelling (design §4.2).
    """

    use Splode.Error,
      fields: [:question_id, :surface],
      class: :forbidden

    def message(%{question_id: question_id, surface: surface}) do
      "#{surface} refused exploratory observation #{question_id} — exploratory rows are " <>
        "never banded, never admitted, never fact-fed (design §4.2; promotion is the only path)"
    end
  end
end
