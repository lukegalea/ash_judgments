# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.Metrics do
  @moduledoc """
  The per-answer-kind calibration metrics (ticket AST-91), as pure
  functions over `(prediction, gold)` pairs, emitting the §8.1 shape:
  maps of DECIMAL STRINGS.

  - **noul** — reliability bins (tenth-width), ECE (expected
    calibration error), Brier score. The §8.1 calibration half.
  - **choice** — per-class precision and recall.
  - **score** — level agreement (exact match on the nearest level) and
    mean absolute error on the position. *The ticket body leaves score
    metrics open; this is the minimal reading* (flagged).
  - **extraction** — the [L]6 standard vocabulary for extraction
    families: `exact_match`, `fabricated_citation`, `false_abstention`,
    `trap_wrong` (the extraction-answer-type design §3).

  Pairs are plain maps so callers shape them from rows without casting
  answer structs: see each function's docs for its pair shape. Floats
  are rendered with shortest-round-trip decimal strings; the ECE/Brier
  arithmetic itself stays in floats — the 1e-9 golden assertions
  compare the FLOATS (a helper returns them) and the strings are their
  stored form.
  """

  @moduledoc since: "0.1.0"

  @bin_count 10

  ## noul — the calibration half of §8.1

  @doc """
  Pairs: `%{p: float 0..1, gold: boolean}`. Returns:

      %{"reliability_bins" => %{...}, "ece" => "0.013", "brier" => "0.081"}

  `raw/1` (below) returns the same with float values for assertions.
  """
  def noul_metrics(pairs) do
    pairs
    |> noul_raw()
    |> render()
  end

  @doc "The noul metrics with float values — the golden assertions' form."
  def noul_raw(pairs) do
    bins = reliability_bins(pairs)
    %{ece: ece, brier: brier} = ece_and_brier(pairs, bins)

    %{reliability_bins: bins, ece: ece, brier: brier}
  end

  @doc "Tenth-width reliability bins: bin i covers [i/10, (i+1)/10); the top bin is closed at 1.0."
  def reliability_bins(pairs) do
    0..(@bin_count - 1)
    |> Map.new(fn i ->
      lower = i / @bin_count

      members =
        Enum.filter(pairs, fn %{p: p} ->
          p >= lower and (p < lower + 1 / @bin_count or (i == @bin_count - 1 and p <= 1.0))
        end)

      n = length(members)

      confidence =
        if n == 0, do: nil, else: Enum.sum(Enum.map(members, & &1.p)) / n

      accuracy =
        if n == 0, do: nil, else: Enum.count(members, & &1.gold) / n

      {bin_name(i), %{"n" => n, "confidence" => confidence, "accuracy" => accuracy}}
    end)
  end

  defp bin_name(i), do: "bin_#{i}"

  defp ece_and_brier(pairs, bins) do
    n = max(length(pairs), 1)

    ece =
      Enum.reduce(bins, 0.0, fn
        {_name, %{"n" => 0, "confidence" => _, "accuracy" => _}}, running ->
          running

        {_name, %{"n" => bin_n, "confidence" => conf, "accuracy" => bin_acc}}, running ->
          running + bin_n / n * abs(conf - bin_acc)
      end)

    brier =
      Enum.sum(Enum.map(pairs, fn %{p: p, gold: gold} -> :math.pow(p - truth(gold), 2) end)) /
        max(length(pairs), 1)

    %{ece: ece, brier: brier}
  end

  defp truth(true), do: 1.0
  defp truth(false), do: 0.0

  ## choice — per-class precision and recall

  @doc """
  Pairs: `%{value: atom | String.t(), gold: atom | String.t()}`. Returns
  `%{"per_class" => %{class => %{"precision" => …, "recall" => …, "n" => …}},
    "accuracy" => …}`.
  """
  def choice_metrics(pairs) do
    classes =
      pairs
      |> Enum.flat_map(&[to_s(&1.value), to_s(&1.gold)])
      |> Enum.uniq()

    per_class =
      Map.new(classes, fn class ->
        predicted = Enum.count(pairs, &(&1 |> to_s(:value) == class))
        golded = Enum.count(pairs, &(&1 |> to_s(:gold) == class))
        correct = Enum.count(pairs, &(&1 |> to_s(:value) == class and &1 |> to_s(:gold) == class))

        precision = if predicted == 0, do: nil, else: correct / predicted
        recall = if golded == 0, do: nil, else: correct / golded

        {class, %{"precision" => precision, "recall" => recall, "n" => golded}}
      end)

    accuracy =
      if pairs == [] do
        nil
      else
        Enum.count(pairs, &(&1 |> to_s(:value) == &1 |> to_s(:gold))) / length(pairs)
      end

    %{"per_class" => per_class, "accuracy" => accuracy}
    |> render()
  end

  ## score — level agreement (the minimal reading; flagged in the moduledoc)

  @doc """
  Pairs: `%{position: number, gold_position: number}`. Returns exact
  level agreement (equal positions) and the mean absolute error.
  """
  def score_metrics(pairs) do
    n = max(length(pairs), 1)

    agreement =
      if pairs == [], do: nil, else: Enum.count(pairs, &(&1.position == &1.gold_position)) / n

    mae =
      if pairs == [],
        do: nil,
        else: Enum.sum(Enum.map(pairs, &abs(&1.position - &1.gold_position))) / n

    %{"level_agreement" => agreement, "mae" => mae}
    |> render()
  end

  ## extraction — the [L]6 vocabulary

  @doc """
  Pairs: `%{answer: %{status, value, source_ids}, gold: %{value, source_ids},
  trap?: boolean}`.

  - `exact_match` — found AND the value equals the gold value, over all items
  - `fabricated_citation` — found AND any source id outside the gold's
    source set, over found items
  - `false_abstention` — gold has a value AND the answer is `not_found` or
    `ambiguous`, over items with a gold value
  - `trap_wrong` — the item is a trap AND the answer was valid but wrong
    (status found, value ≠ gold), over trap items

  Each metric is `nil` when its denominator is zero — an absent metric is
  honest, a zero would be a claim.
  """
  def extraction_metrics(pairs) do
    n = max(length(pairs), 1)

    found = Enum.filter(pairs, &(&1.answer[:status] == :found))
    gold_valued = Enum.filter(pairs, &(value_of(&1.gold) != nil))
    traps = Enum.filter(pairs, &(&1[:trap?] == true))

    %{
      "exact_match" => ratio(pairs, &exact?/1),
      "fabricated_citation" => ratio(found, &fabricated?/1),
      "false_abstention" => ratio(gold_valued, &abstained?/1),
      "trap_wrong" => ratio(traps, &trap_wrong?/1)
    }
    |> put_total(n)
    |> render()
  end

  defp exact?(pair),
    do: pair.answer[:status] == :found and value_of(pair.answer) == value_of(pair.gold)

  defp fabricated?(pair) do
    cited = pair.answer[:source_ids] || []
    gold_ids = MapSet.new(pair.gold[:source_ids] || [])
    cited != [] and Enum.any?(cited, &(&1 not in gold_ids))
  end

  defp abstained?(pair), do: pair.answer[:status] in [:not_found, :ambiguous]

  defp trap_wrong?(pair),
    do: pair.answer[:status] == :found and value_of(pair.answer) != value_of(pair.gold)

  # An absent denominator renders nil — honest absence, not a zero claim.
  defp ratio([], _pred), do: nil
  defp ratio(items, pred), do: Enum.count(items, pred) / length(items)

  defp put_total(metrics, _n), do: metrics

  defp value_of(map) when is_map(map), do: map[:value] || Map.get(map, "value")
  defp value_of(_), do: nil

  defp to_s(pair, key), do: to_s(Map.get(pair, key))
  defp to_s(nil), do: nil
  defp to_s(v) when is_atom(v), do: Atom.to_string(v)
  defp to_s(v), do: to_string(v)

  ## Rendering — §8.1: numbers as decimal strings

  defp render(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp render(value) when is_integer(value), do: Integer.to_string(value)
  defp render(nil), do: nil
  defp render(value) when is_boolean(value), do: value

  defp render(%{} = map) do
    Map.new(map, fn {k, v} -> {render_key(k), render(v)} end)
  end

  defp render(list) when is_list(list), do: Enum.map(list, &render/1)
  defp render(other), do: other

  defp render_key(k) when is_atom(k), do: Atom.to_string(k)
  defp render_key(k), do: k
end
