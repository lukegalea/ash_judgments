# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Exploration.Ordering do
  @moduledoc """
  The labelled ordering spec and its read path (explore-tier design §1).

  **Two phases, always.** A set expression first (the caller's candidate
  set — a CQL2 filter or a retrieval top-N), then an ordering spec that
  decorates the rows a person will read:

      Ordering.resolve(Resource, question_id: "...", selector: :urgent)
      |> Ordering.sort(rows, Ordering.latest_answers(ledger, question_id))

  - the spec resolves against the compile-time registry: `question_id` must
    be DECLARED and `selector` one of the question's derived options;
    unrecognised ids or selectors are validation errors, never silent skips;
  - **no score-only orderings** — ordering by the score itself, without
    naming the set expression it decorates, is refused (thesis 8);
  - a missing score never removes or hides a row — nulls sort last and
    carry no meaning;
  - ordering is decoration, never membership: `sort/3` reorders, it never
    filters.

  Every ordered row can carry the answered-by chip (`chip/1`): profile ·
  model@digest · p · latency. Staleness is a membership concern (S1-53) —
  a stale fact's observation may still order the reading list, the chip
  carrying provenance.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Exploration
  alias AshJudgments.Registry

  defstruct [:source, :question_id, :selector, :direction]

  @type t :: %__MODULE__{
          source: :observation | :retrieval,
          question_id: String.t(),
          selector: term(),
          direction: :asc | :desc
        }

  @doc """
  Resolves an ordering spec against `resource`'s compiled registry.

  Options: `:question_id` (required), `:selector` (required — an option or
  level of the question, including `true`/`false` for a Noul), `:source`
  (default `:observation`; `:retrieval` decorates a retrieval top-N), and
  `:direction` (default `:asc` — the selector's rows first; `:desc` puts
  them last). Returns `{:ok, spec}` or `{:error, exception}`; `resolve!/2`
  raises.
  """
  @spec resolve(module(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def resolve(resource, opts) when is_atom(resource) and is_list(opts) do
    question_id = Keyword.fetch!(opts, :question_id)
    source = Keyword.get(opts, :source, :observation)
    direction = Keyword.get(opts, :direction, :asc)

    unless source in [:observation, :retrieval] do
      raise ArgumentError,
            "ordering source must be :observation or :retrieval, got #{inspect(source)}"
    end

    unless direction in [:asc, :desc] do
      raise ArgumentError,
            "ordering direction must be :asc or :desc, got #{inspect(direction)}"
    end

    with :ok <- check_selector_given(opts, question_id),
         question <-
           Registry.Info.questions(resource) |> Enum.find(&(&1.question_id == question_id)),
         :ok <- check_question(question, question_id, resource),
         :ok <- check_option(question, opts[:selector]) do
      {:ok,
       %__MODULE__{
         source: source,
         question_id: question_id,
         selector: opts[:selector],
         direction: direction
       }}
    end
  end

  @doc "`resolve/2`, raising on a validation failure."
  @spec resolve!(module(), keyword()) :: t()
  def resolve!(resource, opts) do
    case resolve(resource, opts) do
      {:ok, spec} -> spec
      {:error, exception} -> raise exception
    end
  end

  defp check_selector_given(opts, question_id) do
    # Keyword.fetch, not get: `selector: false` is a legitimate Noul
    # selector — an ABSENT selector is the score-only refusal.
    case Keyword.fetch(opts, :selector) do
      {:ok, nil} -> {:error, score_only(question_id, nil)}
      {:ok, _selector} -> :ok
      :error -> {:error, score_only(question_id, nil)}
    end
  end

  defp check_question(nil, question_id, resource),
    do: {:error, %Exploration.UnknownQuestion{question_id: question_id, resource: resource}}

  defp check_question(_question, _question_id, _resource), do: :ok

  defp check_option(question, selector) do
    options = Enum.map(question.options, &normalize_option/1)
    question_id = question.question_id

    cond do
      score_shorthand?(selector) ->
        {:error, score_only(question_id, selector)}

      Enum.any?(selector_variants(selector), &(&1 in options)) ->
        :ok

      true ->
        {:error,
         %Exploration.UnknownSelector{
           selector: selector,
           options: question.options,
           question_id: question_id
         }}
    end
  end

  defp score_only(question_id, selector),
    do: %Exploration.ScoreOnlyOrdering{selector: selector, question_id: question_id}

  # The shorthands that name the score itself — the vocabulary of a
  # score-only ordering, refused before they can look like an unknown
  # option (§1.2).
  @score_shorthands ["score", "magnitude", "position", "value"]

  defp score_shorthand?(selector) when is_binary(selector),
    do: String.downcase(selector) in @score_shorthands

  defp score_shorthand?(selector) when is_atom(selector) and not is_boolean(selector),
    do: Atom.to_string(selector) in @score_shorthands

  defp score_shorthand?(_), do: false

  # Every literal spelling the selector may take: the normalised form plus
  # the boolean/string twin, so `selector: true` and `selector: "true"`
  # both reach the Noul options (`true`/`false` as booleans).
  defp selector_variants(selector) do
    base = normalize_option(selector)

    variants =
      cond do
        is_boolean(selector) ->
          [base, Atom.to_string(selector)]

        is_binary(selector) and selector in ["true", "false"] ->
          [base, selector_variant_atom(selector)]

        true ->
          [base]
      end

    Enum.uniq(variants)
  end

  defp selector_variant_atom("true"), do: true
  defp selector_variant_atom("false"), do: false

  # The canonical option normaliser: atoms as strings, booleans kept —
  # the same rendering the identity hash applies to options.
  defp normalize_option(option) when is_atom(option) and not is_boolean(option),
    do: Atom.to_string(option)

  defp normalize_option(option), do: option

  @doc """
  The §1.3 read: the latest `mode: :live` ANSWERED observation per
  (question, subject) from the host ledger, riding the `[L]5` partial
  index. At the v0 record's field set every recorded row is an answered
  observation (the judge records only successful casts), so live+answered
  reduces to `mode = :live`; a host whose record carries the §5.5
  `outcome` column adds that conjunct on its own action.

  The read is tenant-scoped through Ash multitenancy when the host sets a
  tenant. Returns a map of `{{subject_type, subject_id}, record}`.
  """
  @spec latest_answers(module(), String.t(), keyword()) ::
          %{{String.t(), String.t() | nil} => term()}
  def latest_answers(ledger, question_id, opts \\ []) do
    ledger
    |> Ash.Query.for_read(:latest_answered, %{question_id: question_id}, tenant: opts[:tenant])
    |> Ash.read!()
    |> Map.new(fn record -> {{record.subject_type, record.subject_id}, record} end)
  end

  @doc """
  Decorates the candidate `rows` with `records` (the `latest_answers/3`
  map, or a list of the same observations): rows whose latest live
  answered observation for the spec's question collapses to the spec's
  selector sort first (`:asc`) or last (`:desc`); every other row keeps
  the candidate set's declared order; rows with NO observation sort last
  regardless of direction — a missing score carries no meaning.

  `sort/3` never filters: the result is a permutation of `rows`.
  """
  @spec sort([term()], term(), t()) :: [term()]
  def sort(rows, records, %__MODULE__{} = spec) when is_list(rows) do
    by_subject = index(records)

    {nulls, scored} =
      Enum.split_with(rows, fn row ->
        record = by_subject[row_key(row)]
        record == nil or collapse(record) == nil
      end)

    {matches, nonmatches} =
      Enum.split_with(scored, fn row ->
        matches?(by_subject[row_key(row)], spec.selector)
      end)

    case spec.direction do
      :asc -> matches ++ nonmatches ++ nulls
      :desc -> nonmatches ++ matches ++ nulls
    end
  end

  defp index(records) when is_map(records), do: records

  defp index(records) when is_list(records) do
    Map.new(records, fn record ->
      {{Map.get(record, :subject_type), Map.get(record, :subject_id)}, record}
    end)
  end

  defp row_key(row), do: {Map.get(row, :subject_type), Map.get(row, :subject_id)}

  defp matches?(record, selector) do
    case collapse(record) do
      nil -> false
      collapsed -> Enum.any?(selector_variants(selector), &(&1 == normalize_option(collapsed)))
    end
  end

  @doc """
  The collapsed value an observation answers with, in the question's own
  vocabulary — the option (Choice), the winning level (Score, by argmax
  over the recorded distribution, the same derivation the cache rebuild
  applies), or `true`/`false` (Noul, from the derived two-leg
  distribution). `nil` when the row carries no collapsible answer at this
  record fidelity (an extraction's status is not on the v0 row — it
  carries no meaning here, so it sorts last).

  `levels` names the Score levels when the caller knows the question;
  without them the winning level is its distribution index.
  """
  @spec collapse(term(), [term()] | nil) :: term() | nil
  def collapse(record, levels \\ nil)

  def collapse(record, levels) when is_map(record) do
    probabilities = Map.get(record, :probabilities) || %{}

    case Map.get(record, :answer_kind) do
      :noul -> collapse_noul(probabilities)
      :choice -> normalize_option(Map.get(record, :value))
      :score -> collapse_score(probabilities, levels)
      # The v0 row carries the cast value, not the status — a selector
      # over the status vocabulary has nothing to match on (§1.2: nulls
      # carry no meaning).
      kind when kind in [:extraction, :evidence] -> nil
      _kind -> normalize_option(Map.get(record, :value))
    end
  end

  def collapse(_record, _levels), do: nil

  # The Noul's derived two-leg distribution: the winning side.
  defp collapse_noul(probabilities) do
    p_true = parse_float(probabilities["true"])
    p_false = parse_float(probabilities["false"])

    if p_true != nil and p_false != nil and p_true >= p_false, do: true, else: false
  end

  # The Score's winning level, by argmax over the recorded distribution —
  # the same derivation the cache rebuild applies. Without the question's
  # levels, the winner is its distribution index.
  defp collapse_score(probabilities, levels) do
    {index, _p} =
      probabilities
      |> Enum.max_by(fn {_k, p} -> parse_float(p) || 0.0 end, fn -> {nil, 0.0} end)

    case index do
      nil ->
        nil

      index when is_integer(index) ->
        Enum.at(List.wrap(levels), index) || Integer.to_string(index)

      index ->
        index
    end
  end

  defp parse_float(nil), do: nil

  defp parse_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  @doc """
  The answered-by chip (SYNTHESIS §2.1): profile · model@digest · p ·
  latency. Provenance only — it labels a row, it never ranks by itself.
  """
  @spec chip(term()) :: %{
          profile: String.t(),
          model: String.t() | nil,
          p: String.t() | nil,
          latency_us: integer() | nil
        }
  def chip(record) when is_map(record) do
    probabilities = Map.get(record, :probabilities) || %{}

    p =
      probabilities
      |> Enum.map(fn {_k, v} -> parse_float(v) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    %{
      profile: Map.get(record, :profile),
      model: model_at_digest(record),
      p: p && :erlang.float_to_binary(p, [:short]),
      latency_us: Map.get(record, :latency_us)
    }
  end

  defp model_at_digest(record) do
    version = Map.get(record, :model_version)
    digest = Map.get(record, :model_digest)

    cond do
      version && digest -> "#{version}@#{digest}"
      version -> version
      true -> nil
    end
  end
end
