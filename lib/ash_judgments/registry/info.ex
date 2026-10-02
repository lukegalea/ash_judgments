# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Info do
  @moduledoc """
  Introspection for compiled question registries. The declaration is the
  shared schema: these functions are how the manifest, the docs, the agent
  tooling and the audit pack see the model surface.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Registry.Question
  alias Spark.Dsl.Extension

  @doc "Every question declared on the resource, in declaration order."
  @spec questions(module()) :: [Question.t()]
  def questions(resource) when is_atom(resource) do
    if Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0) do
      Extension.get_persisted(resource, :questions, [])
    else
      []
    end
  end

  @doc "One declared question by name, or `nil`."
  @spec question(module(), atom()) :: Question.t() | nil
  def question(resource, name) when is_atom(resource) and is_atom(name) do
    resource
    |> questions()
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  The question's `question_hash` — its identity in the ledger (RFC §3.2) —
  or `nil` when the resource declares no such question.
  """
  @spec hash(module(), atom()) :: String.t() | nil
  def hash(resource, name) when is_atom(resource) and is_atom(name) do
    case question(resource, name) do
      %Question{question_hash: hash} -> hash
      nil -> nil
    end
  end
end
