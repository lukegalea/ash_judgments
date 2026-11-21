# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.Banding.AutomatedShare do
  @moduledoc """
  How much of each family's live work its band table settles without a
  person, week by week: the implementation of a host calibration-run
  resource's generic action, the report on the `AshJudgments.A2ui.Calibration`
  surface. The runs on the same surface carry their `:coverage`, the share
  their table decided without review on the calibration items, so the two
  can be read side by side.

  ```elixir
  action :automated_share, {:array, :map} do
    run {AshJudgments.Banding.AutomatedShare,
         banding_resource: MyApp.SystemOne.Banding,
         judgment_resource: MyApp.SystemOne.Judgment}
  end
  ```

  It reads, as the actor and in the action's tenant, the families of the
  calibration runs (the action's own resource), every `:live` banding of
  the banding resource, and every `:live` observation of the judgment
  ledger. That is three queries, whatever the number of families or weeks;
  the grouping by family and week (starting Monday, UTC) is done here.

  The live work is the live answers. One a live banding names is counted
  under its band, in the week it was banded. One no live banding names is
  **not banded**, in the week it was recorded: the table refused it (no
  rule matched), it was never banded (an unknown answer, a failed call, no
  published table), or it waits to be. Leaving those out would show the
  settled share of what was banded as the settled share of the work.
  Shadow bandings and shadow, calibration and eval observations are left
  out, because nothing acted on them.

  One row per family and week, in family then week order:

  - `family`, `week` (the Monday, an ISO 8601 date) and `answers`, the
    count of the week's live answers;
  - `admitted`, `review`, `omitted` and `not_banded`: each one's count and
    its share of the week's answers, as `"12 (60%)"`.

  A family with calibration runs and no live answers yet gets one row
  whose `week` says so and whose shares are `"—"`: there is nothing to
  divide. A family whose table has no review band shows `"0 (0%)"` under
  `review`. No model is called, and nothing is written.
  """
  @moduledoc since: "0.3.4"

  use Ash.Resource.Actions.Implementation

  require Ash.Expr
  require Ash.Query

  @outcomes [admit: :admitted, review: :review, omit: :omitted, not_banded: :not_banded]

  @impl true
  def run(input, opts, context) do
    banding_resource = Keyword.fetch!(opts, :banding_resource)
    judgment_resource = Keyword.fetch!(opts, :judgment_resource)
    read_opts = Ash.Context.to_opts(context)

    with {:ok, runs} <- input.resource |> Ash.Query.select([:family]) |> Ash.read(read_opts),
         {:ok, bandings} <- banding_resource |> live_bandings() |> Ash.read(read_opts),
         {:ok, answers} <- judgment_resource |> live_answers() |> Ash.read(read_opts) do
      {:ok, rows(Enum.map(runs, & &1.family), work(bandings, answers))}
    end
  end

  defp live_bandings(resource) do
    resource
    |> Ash.Query.filter(mode == :live)
    |> Ash.Query.select([:band, :banded_at, :observation_ids])
    |> Ash.Query.calculate(:share_family, :string, Ash.Expr.expr(inputs["family"]))
  end

  defp live_answers(resource) do
    resource
    |> Ash.Query.filter(mode == :live and not is_nil(family))
    |> Ash.Query.select([:family, :recorded_at])
  end

  # Each piece of live work as {family, when, outcome}.
  defp work(bandings, answers) do
    banded = bandings |> Enum.flat_map(& &1.observation_ids) |> MapSet.new()

    settled =
      for banding <- bandings,
          do: {banding.calculations.share_family, banding.banded_at, banding.band}

    unsettled =
      for answer <- answers,
          not MapSet.member?(banded, answer.id),
          do: {answer.family, answer.recorded_at, :not_banded}

    settled ++ unsettled
  end

  defp rows(run_families, work) do
    by_family = Enum.group_by(work, &elem(&1, 0))

    (run_families ++ Map.keys(by_family))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&family_rows(&1, Map.get(by_family, &1, [])))
  end

  defp family_rows(family, []) do
    [
      Map.merge(
        %{family: family, week: "no live answers yet", answers: 0},
        Map.new(@outcomes, fn {_outcome, column} -> {column, "—"} end)
      )
    ]
  end

  defp family_rows(family, work) do
    work
    |> Enum.group_by(fn {_family, at, _outcome} -> week(at) end)
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map(fn {week, in_week} ->
      counts = Enum.frequencies_by(in_week, &elem(&1, 2))
      total = length(in_week)

      Map.merge(
        %{family: family, week: Date.to_iso8601(week), answers: total},
        Map.new(@outcomes, fn {outcome, column} -> {column, share(counts[outcome], total)} end)
      )
    end)
  end

  defp week(at), do: at |> DateTime.to_date() |> Date.beginning_of_week()

  defp share(count, total) do
    count = count || 0
    "#{count} (#{round(count * 100 / total)}%)"
  end
end
