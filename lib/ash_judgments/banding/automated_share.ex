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
    run {AshJudgments.Banding.AutomatedShare, banding_resource: MyApp.SystemOne.Banding}
  end
  ```

  It reads, as the actor and in the action's tenant, the families of the
  calibration runs (the action's own resource) and every `:live` banding
  of the banding resource, selecting only the band, `banded_at` and the
  family input. That is two queries, whatever the number of families or
  weeks; the grouping by family and week (starting Monday, UTC) is done
  here. Shadow bandings are left out, because nothing acted on them.

  One row per family and week, in family then week order:

  - `family`, `week` (the Monday, an ISO 8601 date) and `bandings`, the
    count;
  - `admitted`, `review` and `omitted`: each band's count and its share of
    the week's bandings, as `"12 (60%)"`.

  A family with calibration runs and no bandings yet gets one row whose
  `week` says so and whose shares are `"—"`: there is nothing to divide.
  A family whose table has no review band shows `"0 (0%)"` under
  `review`. No model is called, and nothing is written.
  """
  @moduledoc since: "0.3.4"

  use Ash.Resource.Actions.Implementation

  require Ash.Expr
  require Ash.Query

  @impl true
  def run(input, opts, context) do
    banding_resource = Keyword.fetch!(opts, :banding_resource)
    read_opts = Ash.Context.to_opts(context)

    with {:ok, runs} <- input.resource |> Ash.Query.select([:family]) |> Ash.read(read_opts),
         {:ok, bandings} <- banding_resource |> live_bandings() |> Ash.read(read_opts) do
      {:ok, rows(Enum.map(runs, & &1.family), bandings)}
    end
  end

  defp live_bandings(resource) do
    resource
    |> Ash.Query.filter(mode == :live)
    |> Ash.Query.select([:band, :banded_at])
    |> Ash.Query.calculate(:share_family, :string, Ash.Expr.expr(inputs["family"]))
  end

  defp rows(run_families, bandings) do
    by_family = Enum.group_by(bandings, & &1.calculations.share_family)

    (run_families ++ Map.keys(by_family))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&family_rows(&1, Map.get(by_family, &1, [])))
  end

  defp family_rows(family, []) do
    [
      %{
        family: family,
        week: "no bandings yet",
        bandings: 0,
        admitted: "—",
        review: "—",
        omitted: "—"
      }
    ]
  end

  defp family_rows(family, bandings) do
    bandings
    |> Enum.group_by(&week/1)
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map(fn {week, in_week} ->
      counts = Enum.frequencies_by(in_week, & &1.band)
      total = length(in_week)

      %{
        family: family,
        week: Date.to_iso8601(week),
        bandings: total,
        admitted: share(counts[:admit], total),
        review: share(counts[:review], total),
        omitted: share(counts[:omit], total)
      }
    end)
  end

  defp week(banding), do: banding.banded_at |> DateTime.to_date() |> Date.beginning_of_week()

  defp share(count, total) do
    count = count || 0
    "#{count} (#{round(count * 100 / total)}%)"
  end
end
