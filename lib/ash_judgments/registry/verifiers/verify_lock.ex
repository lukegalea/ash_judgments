# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Verifiers.VerifyLock do
  @moduledoc """
  A hash change requires a version bump — checked at compile time against
  the committed `priv/judgments/lock.json`, in the spirit of
  `ash.codegen --check` (CORE-REGISTRY/AC-3).

  Question wording is policy: a reworded question is a *new question*
  (law 4), and the version field is what says so. When a question's
  `question_hash` differs from the locked hash while the locked version is
  unchanged, compilation fails naming the question and both hashes. Bump
  `version`, or regenerate the lock with
  `mix ash_judgments.judgments.lock` when the change is intended and
  reviewed.

  The check is active when the lock file exists — a host opts in by
  committing it (an empty `[]` is enough). The path is
  `config :ash_judgments, :lock_path` (default `priv/judgments/lock.json`,
  relative to the compiling project root). The transformer declares the
  file an `@external_resource` of the resource, so editing the lock
  recompiles the questions that read it.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Transformer

  @impl true
  def verify(dsl_state) do
    path = lock_path()

    case read_lock(path) do
      :no_lock ->
        :ok

      {:error, reason} ->
        # A committed lock that cannot be parsed is never silently skipped.
        {:error,
         Spark.Error.DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:judgments],
           message: "the question lock at #{path} could not be read: #{inspect(reason)}"
         )}

      {:ok, lock} ->
        module = Transformer.get_persisted(dsl_state, :module)

        dsl_state
        |> Transformer.get_entities([:judgments])
        |> Enum.flat_map(&lock_errors(&1, lock, module, path))
        |> case do
          [] -> :ok
          errors -> {:error, errors}
        end
    end
  end

  @doc false
  @spec lock_path() :: String.t()
  def lock_path, do: Application.get_env(:ash_judgments, :lock_path, "priv/judgments/lock.json")

  @doc false
  @spec read_lock(String.t()) :: :no_lock | {:error, term()} | {:ok, map()}
  def read_lock(path) do
    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      # `[]` is the documented empty lock (opted in, constraining nothing);
      # any other non-object shape is malformed.
      {:ok, normalize(decoded)}
    else
      false -> :no_lock
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(entries) when entries == [] or entries == nil, do: %{}
  defp normalize(entries) when is_map(entries), do: entries

  defp normalize(_other),
    do: raise(ArgumentError, "the lock must be a JSON object of question_id => {hash, version}")

  defp lock_errors(question, lock, module, path) do
    case Map.fetch(lock, question.question_id) do
      :error ->
        # A question the lock does not know yet: the lock task adds it.
        []

      {:ok, %{"hash" => locked_hash, "version" => locked_version}} ->
        cond do
          locked_hash == question.question_hash ->
            []

          locked_version == question.version ->
            [
              Spark.Error.DslError.exception(
                module: module,
                path: [:judgments, question.name, :version],
                message:
                  "the declaration changed without a version bump (lock #{path}): " <>
                    "question #{question.question_id} declared #{question.question_hash}, " <>
                    "locked #{locked_hash} at version #{question.version}. " <>
                    "Bump `version` (a changed question is a new question, law 4), " <>
                    "or run `mix ash_judgments.judgments.lock` if the change is reviewed"
              )
            ]

          true ->
            # Hash changed AND version bumped: the intended flow. The lock
            # task refreshes the entry; until it runs, the declared hash is
            # what feeds the ledger.
            []
        end

      {:ok, _other} ->
        [
          Spark.Error.DslError.exception(
            module: module,
            path: [:judgments, question.name],
            message:
              "the lock entry for #{question.question_id} is malformed (expected {\"hash\", \"version\"})"
          )
        ]
    end
  end
end
