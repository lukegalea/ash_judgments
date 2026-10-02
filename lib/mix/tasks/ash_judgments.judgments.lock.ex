# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshJudgments.Judgments.Lock do
  @shortdoc "Regenerate priv/judgments/lock.json for every declared question"
  @moduledoc """
  Regenerates the question lock — `priv/judgments/lock.json`, the file the
  compile-time version-bump check reads (CORE-REGISTRY/AC-3).

  Run it after a reviewed question change that bumps `version` (or when
  first adopting the check). With no arguments it scans every *loaded* Ash
  resource carrying the `judgments` section; explicit resource modules can
  be passed to narrow the run:

      mix ash_judgments.judgments.lock
      mix ash_judgments.judgments.lock MyApp.Appointment

  The lock maps each `question_id` to its `question_hash` and `version`.
  A declared question missing from the lock is added; entries for
  questions that no longer exist are dropped. Compile afterwards: the
  version-bump verifier only stays quiet when every changed hash arrives
  with a bumped version.
  """

  use Mix.Task

  alias Spark.Dsl.Extension

  # app.config + compile: the task reads compiled resource modules; it
  # must not boot the host application (queues, projectors, endpoints —
  # law 23).
  @requirements ["app.config", "compile"]

  @impl Mix.Task
  def run(args) do
    resources =
      case args do
        [] -> scan_loaded()
        names -> Enum.map(names, &String.to_existing_atom/1)
      end

    case resources do
      [] ->
        Mix.shell().info(
          "no question registries found (loaded resources with a `judgments` section)"
        )

      resources ->
        entries =
          resources
          |> Enum.flat_map(&questions_of/1)
          |> Map.new(fn question ->
            {question.question_id,
             %{"hash" => question.question_hash, "version" => question.version}}
          end)

        path = AshJudgments.Registry.Verifiers.VerifyLock.lock_path()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(entries, pretty: true) <> "\n")

        Mix.shell().info(
          "locked #{map_size(entries)} question(s) across #{length(resources)} resource(s) -> #{path}"
        )

        {:ok, entries}
    end
  end

  defp questions_of(resource) do
    if Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0) do
      Extension.get_persisted(resource, :questions, [])
    else
      []
    end
  end

  # Every module of THIS project that is an Ash resource carrying the
  # judgments section. Explicit arguments (the common case in CI) skip the
  # scan. The scan walks the project's own beams and loads them by absolute
  # path (no atom synthesis — law 10) — under `app.config` + `compile`
  # (law 23) nothing else is loaded for us.
  defp scan_loaded do
    app_ebin = Mix.Project.compile_path() |> Path.expand()

    :code.all_available()
    |> Enum.map(fn
      {name, path, _loaded} when is_list(path) ->
        {name |> List.to_string() |> IO.iodata_to_binary(), List.to_string(path)}

      {name, path, _loaded} when is_binary(path) ->
        {IO.iodata_to_binary(name), path}

      # Preloaded and in-memory modules have no beam path to walk.
      {_name, _path, _loaded} ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn {_name, path} ->
      Path.dirname(path) == app_ebin
    end)
    |> Enum.map(fn {_name, path} ->
      # :code.load_abs takes the absolute beam path WITHOUT the extension.
      abs = String.trim_trailing(path, ".beam")

      case :code.load_abs(String.to_charlist(abs)) do
        {:module, module} -> module
        _error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn module ->
      function_exported?(module, :spark_is, 0) and
        module.spark_is() == Ash.Resource and
        match?([_ | _], Extension.get_persisted(module, :questions, []))
    end)
    |> Enum.uniq()
  end
end
