# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.Banding.Review do
  @moduledoc """
  What a person needs to judge a banding in review: the banding fragment's
  `:subject`, `:question_text`, `:lean`, `:judged_text` and
  `:judged_excerpt` calculations. They read what was recorded (the
  observations, the question's declaration, the inputs the table read)
  and never recompute a band.

  - `:subject`: the observations' `subject_id` (a function, a document
    section), joined by `", "` when they differ.
  - `:question_text`: the question's declared instructions, from the
    registry, for the observation's `question_id`, and only while its
    `question_hash` still matches the declaration: a reworded question is
    not shown as the one the model was asked (nil instead).
  - `:lean`: the model's lean in words, from the score the table read and
    the thresholds of the table version the banding recorded, as in
    "leans yes, 0.70; 0.77 admits without review". The numbers are the
    model's probability of yes. When the thresholds cannot be read (no
    `AshJudgments.Banding.ReviewSource`, or it cannot read that version)
    it says so rather than guess.
  - `:judged_text`: the text the model judged, the observation's sealed
    state opened by the host's `ReviewSource.open_state/2` as the actor.
    nil without an actor, without a review source, or when the source
    returns none.
  - `:judged_excerpt`: the same text on one line, cut to 280 characters
    at a word boundary (`max_length:` overrides) for a row.

  The observations are read from the host's ledger,
  `config :ash_judgments, :ledger` (or the `judgment_resource:` option),
  with the actor, tenant and authorization the calculation runs with. The
  review source is `config :ash_judgments, :review_source` (or the
  `review_source:` option).
  """
  @moduledoc since: "0.3.3"

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshJudgments.Banding.{Display, ReviewSource}
  alias AshJudgments.Calibration.ProposalDmn
  alias AshJudgments.Registry.Info

  @excerpt_length 280

  @impl true
  def load(_query, opts, _context) do
    case opts[:field] do
      :lean -> [:inputs, :band_table, :decision_evaluation_id, :observation_ids]
      _ -> [:observation_ids]
    end
  end

  @impl true
  def calculate(records, opts, context) do
    case opts[:field] do
      :subject -> per_banding(records, opts, context, &subject/1)
      :question_text -> per_banding(records, opts, context, &question_text/1)
      :judged_text -> judged(records, opts, context, & &1)
      :judged_excerpt -> judged(records, opts, context, &excerpt(&1, opts[:max_length]))
      :lean -> lean(records, opts, context)
    end
  end

  ## The observations, read as the actor

  defp per_banding(records, opts, context, fun) do
    observations = observations(records, opts, context)

    Enum.map(records, fn banding ->
      case observations_of(banding, observations) do
        [] -> nil
        rows -> fun.(rows)
      end
    end)
  end

  defp observations(records, opts, context) do
    resource = opts[:judgment_resource] || AshJudgments.Ledger.resource()
    ids = records |> Enum.flat_map(&(&1.observation_ids || [])) |> Enum.uniq()

    if resource && ids != [] do
      resource
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read(Ash.Context.to_opts(context))
      |> case do
        {:ok, rows} -> Map.new(rows, &{&1.id, &1})
        {:error, _} -> %{}
      end
    else
      %{}
    end
  end

  defp observations_of(banding, observations) do
    (banding.observation_ids || [])
    |> Enum.map(&Map.get(observations, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp subject(rows), do: join_unique(rows, & &1.subject_id, ", ")

  defp question_text(rows), do: join_unique(rows, &declared_wording/1, "\n")

  defp join_unique(rows, fun, separator) do
    case rows |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> nil
      values -> Enum.join(values, separator)
    end
  end

  # The question's instructions while the declaration still hashes to what
  # the observation recorded. The id names the declaring module and the
  # question; neither becomes a new atom (law 10).
  defp declared_wording(%{question_id: "judgment:v0:" <> rest, question_hash: hash}) do
    with [module_name, name] <- String.split(rest, "#judgments/", parts: 2),
         {:ok, module} <- existing_module(module_name),
         {:ok, name} <- existing_atom(name),
         %{question_hash: ^hash, instructions: instructions} <- Info.question(module, name) do
      instructions
    else
      _ -> nil
    end
  end

  defp declared_wording(_observation), do: nil

  defp existing_module(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  ## The judged text, opened by the host as the actor

  defp judged(records, opts, context, shape) do
    source = opts[:review_source] || ReviewSource.configured()

    if context.actor != nil and exports?(source, :open_state, 2) do
      observations = observations(records, opts, context)
      texts = opened(source, Map.values(observations), context)

      Enum.map(records, &text_of(&1, observations, texts, shape))
    else
      Enum.map(records, fn _ -> nil end)
    end
  end

  defp text_of(banding, observations, texts, shape) do
    banding
    |> observations_of(observations)
    |> Enum.map(&Map.get(texts, &1.id))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> nil
      parts -> parts |> Enum.join("\n\n") |> shape.()
    end
  end

  defp opened(_source, [], _context), do: %{}

  defp opened(source, observations, context) do
    case source.open_state(observations, Ash.Context.to_opts(context)) do
      texts when is_map(texts) -> texts
      _ -> %{}
    end
  end

  @doc """
  The text on one line (whitespace collapsed), cut to `max_length`
  characters (default 280) at the last word boundary before it, with " …"
  when it was cut.
  """
  @spec excerpt(String.t() | nil, pos_integer() | nil) :: String.t() | nil
  def excerpt(text, max_length \\ nil)
  def excerpt(nil, _max_length), do: nil

  def excerpt(text, max_length) do
    max_length = max_length || @excerpt_length
    flat = text |> String.split() |> Enum.join(" ")

    if String.length(flat) <= max_length do
      flat
    else
      cut = String.slice(flat, 0, max_length)

      cut =
        case String.split(cut, " ") do
          [_one_word] -> cut
          words -> words |> Enum.drop(-1) |> Enum.join(" ")
        end

      String.trim_trailing(cut) <> " …"
    end
  end

  ## The lean, against the thresholds the banding's table version held

  defp lean(records, opts, context) do
    source = opts[:review_source] || ReviewSource.configured()
    thresholds = thresholds(records, source, context)

    Enum.map(records, fn banding ->
      describe_lean(banding.inputs || %{}, Map.get(thresholds, banding.band_table))
    end)
  end

  defp thresholds(records, source, context) do
    if exports?(source, :band_table, 2) do
      records
      |> Enum.uniq_by(& &1.band_table)
      |> Map.new(fn banding ->
        {banding.band_table, read_thresholds(source, banding, context)}
      end)
    else
      %{}
    end
  end

  defp read_thresholds(source, banding, context) do
    with {:ok, xml} <- source.band_table(banding, Ash.Context.to_opts(context)),
         {:ok, thresholds} <- ProposalDmn.thresholds(xml) do
      thresholds
    else
      _ -> nil
    end
  end

  @doc """
  The lean in words, from a banding's recorded `inputs` and the thresholds
  of its table version (`ProposalDmn.thresholds/1`'s map, or nil when
  they could not be read). nil when the inputs carry no score.
  """
  @spec describe_lean(map(), map() | nil) :: String.t() | nil
  def describe_lean(inputs, thresholds) do
    with [question | _] <- Display.questions(inputs),
         {kind, score} when not is_nil(score) <- score_of(inputs, question),
         {:ok, decimal} <- parse(score) do
      leaning(kind, inputs, question, decimal, thresholds) <> "; " <> admits(kind, thresholds)
    else
      _ -> nil
    end
  end

  defp score_of(inputs, question) do
    case inputs["#{question}__p_true"] do
      nil -> {:choice, inputs["#{question}__confidence"]}
      p -> {:noul, p}
    end
  end

  defp leaning(:noul, _inputs, _question, p, thresholds) do
    shown = shown(p, thresholds)

    case Decimal.compare(p, Decimal.new("0.5")) do
      :gt -> "leans yes, #{shown}"
      :lt -> "leans no, #{shown} for yes"
      :eq -> "no lean, #{shown}"
    end
  end

  defp leaning(:choice, inputs, question, confidence, thresholds) do
    "answers #{inputs["#{question}__value"]} at #{shown(confidence, thresholds)}"
  end

  defp admits(_kind, nil), do: "the threshold of its band table is not known here"

  defp admits(:noul, %{threshold: t, threshold_low: low, low_band: :admit_no})
       when is_binary(low),
       do: "#{t} admits yes and #{low} admits no without review"

  defp admits(:noul, %{threshold: t, threshold_low: low, low_band: :omit}) when is_binary(low),
    do: "#{t} admits yes without review; #{low} or below is dropped"

  defp admits(_kind, %{threshold: t}), do: "#{t} admits without review"

  # Two decimals, unless rounding would put the score on the other side
  # of a threshold; then the score as the table read it.
  defp shown(score, thresholds) do
    rounded = Decimal.round(score, 2)

    same_side? =
      thresholds
      |> threshold_values()
      |> Enum.all?(&(Decimal.compare(rounded, &1) == Decimal.compare(score, &1)))

    if same_side?, do: Decimal.to_string(rounded, :normal), else: Decimal.to_string(score)
  end

  defp threshold_values(nil), do: []

  defp threshold_values(thresholds) do
    [thresholds[:threshold], thresholds[:threshold_low]]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn value ->
      case parse(value) do
        {:ok, decimal} -> [decimal]
        :error -> []
      end
    end)
  end

  defp parse(value) do
    case Decimal.parse(to_string(value)) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp exports?(nil, _fun, _arity), do: false

  defp exports?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
end
