# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshJudgments.Shadow do
  @shortdoc "Re-run recorded live judgments through a candidate instrument"
  @moduledoc """
  The shadow re-run (CORE-CACHE): replays the STATE of recorded `:live`
  judgments through a candidate instrument, writing `mode: :shadow` rows
  with `shadow_of` — the model-upgrade path (law 6: a model upgrade is a
  rule change, evaluated in shadow before it is a change).

      mix ash_judgments.shadow --family clinic_notes --candidate my_candidate
      mix ash_judgments.shadow --family clinic_notes --candidate c2 \\
        --since 2026-10-01T00:00:00Z --limit 100

  `--candidate` is the candidate PROFILE name (resolved through the
  profile registry, AST-86). `--family` scopes the re-run; `--since`
  bounds it by `recorded_at`; `--limit` caps the rows.

  ## The two host-supplied seams, stated plainly

  **The state** (DEC-PRIVACY consequence): the ledger stores the state's
  DIGEST, not its content — a shadow re-run needs a host-supplied
  resolver from digest to state:

      config :ash_judgments, :state_resolver, {MyApp.Stores, :resolve, []}
      # resolve(digest) -> {:ok, state_map} | :error

  **The call path**: judge actions are resource-specific (the registry
  generates them per resource), so the re-run itself is also a host seam:

      config :ash_judgments, :shadow_runner, {MyApp.SystemOne, :rerun, []}
      # rerun(judgment, candidate_profile_name, state) ->
      #   runs the host's judge action with mode: :shadow through the
      #   candidate profile and records via Ledger.Record — the package's
      #   own contract, the host's transport.

  Without either seam the task REFUSES, reporting how many rows it would
  have re-run: shadow evaluation over digests alone is not possible, and
  the task would rather refuse than silently fabricate.
  """

  use Mix.Task

  require Ash.Query

  # app.config + compile: the task reads compiled resources and the host's
  # stores; it must not boot queues or endpoints (law 23).
  @requirements ["app.config", "compile"]

  @switches [family: :string, candidate: :string, since: :string, limit: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    family = opts[:family] || Mix.raise("ash_judgments.shadow requires --family")
    candidate = opts[:candidate] || Mix.raise("ash_judgments.shadow requires --candidate PROFILE")
    since = parse_since(opts[:since])
    limit = opts[:limit] || 100

    ledger =
      Application.get_env(:ash_judgments, :ledger) ||
        Mix.raise("ash_judgments.shadow requires config :ash_judgments, :ledger")

    candidates =
      ledger
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(family == ^family and mode == :live)
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.Query.limit(limit)
      |> then(fn q -> if since, do: Ash.Query.filter(q, recorded_at >= ^since), else: q end)
      |> Ash.read!()

    case candidates do
      [] ->
        Mix.shell().info("no live judgments for family #{inspect(family)} — nothing to shadow")

      candidates ->
        run_shadow(candidates, candidate)
    end
  end

  defp parse_since(nil), do: nil

  defp parse_since(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> Mix.raise("--since expects an ISO-8601 UTC timestamp, got: " <> inspect(raw))
    end
  end

  defp run_shadow(candidates, candidate) do
    resolver = Application.get_env(:ash_judgments, :state_resolver)
    runner = Application.get_env(:ash_judgments, :shadow_runner)

    missing =
      [
        {:state_resolver, resolver},
        {:shadow_runner, runner}
      ]
      |> Enum.filter(&is_nil(elem(&1, 1)))

    if missing != [] do
      Mix.raise("""
      ash_judgments.shadow cannot re-run: the ledger stores the state's
      DIGEST, not its content (DEC-PRIVACY), and judge actions are
      resource-specific. Configure both seams and re-run:

          config :ash_judgments, :state_resolver, {MyApp.Stores, :resolve, []}
          config :ash_judgments, :shadow_runner, {MyApp.SystemOne, :rerun, []}
      """)
    end

    {rm, rf, ra} = resolver
    {sm, sf, sa} = runner

    results =
      candidates
      |> Enum.map(fn judgment ->
        with {:ok, state} <- apply(rm, rf, [judgment.state_digest | ra]) do
          {:ok, apply(sm, sf, [judgment, candidate, state | sa])}
        else
          _ -> {:skipped, judgment}
        end
      end)

    shadowed = Enum.count(results, &match?({:ok, _}, &1))
    skipped = Enum.count(results, &match?({:skipped, _}, &1))

    Mix.shell().info(
      "shadow run: #{shadowed} re-run through #{inspect(candidate)}, #{skipped} skipped " <>
        "(digest unresolved), of #{length(candidates)} candidate rows"
    )
  end
end
