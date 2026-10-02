# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Rules do
  @moduledoc """
  The `ash_rules` bridge — **ticket AST-93** (CORE-BRIDGE-RULES).

  System One is a fact producer, never an evaluator. This bridge reads the
  **materialised facts table** (`config :ash_judgments, :facts` — NOT the
  ledger: omission-by-absence, grade floors, staleness and expiry are the
  facts table's job per S1-53) and emits `{subject, predicate, value}`
  facts plus provenance for the direct evaluator and the ash_compliance
  guard path. The ledger joins only as provenance display, via
  `fact.admission_id`.

  The guard path must not call a model: every function here reads the
  facts table synchronously — the nondeterministic instrument call
  happened upstream of these rows (law 2).

  ## Escalate-means-omission

  Every fact-schema entry this bridge declares carries `missing:
  :unknown`: an absent fact is `unknown`, never `false`. The materialiser
  (S1-53) enforces the write side — `review` opens a task and writes
  nothing; `omit` supersedes so the predicate returns to `unknown` for
  every consumer; stale and expired facts are read-side states that only
  a superseding decision moves, never a delete.

  ## Value encoding ([L]1)

  Facts carry SCALAR JSON (`true`, `"urgent"`, `80`) — the set
  evaluator's data-layer filter and strict `values_equal?/2`
  re-verification hit scalar probes directly. Wrapper maps only for
  genuinely composite values (extraction structs), where the schema entry
  declares `:map`. See `AshJudgments.Facts.ScalarJson`.

  Requires the optional `ash_rules` dependency for the schema/evaluator
  helpers; the pure data functions (`fact_schema_entries/1`) are
  dependency-free. Degraded (absent dep) calls return
  `{:error, {:missing_dependency, :ash_rules}}` and never raise.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Registry.Canonical

  @type wanted() :: [AshJudgments.Registry.Question.t() | String.t()]

  @doc """
  `:ok` when the `ash_rules` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_rules}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_rules}}
  def available? do
    AshJudgments.Availability.ensure(:ash_rules)
  end

  @doc """
  Judged questions → fact-schema ENTRIES (plain data, one map per
  question): `name` is the question_id string (§3.1 — one namespace with
  crisp fact-schema names), `type` per answer kind (`:boolean` for a
  Noul, `:string` for a Choice/Evidence — the option vocabulary rides in
  `:one_of`, `:number` for a Score's position), and `missing: :unknown`
  — escalate-means-omission: an absent fact is unknown, never false
  (law 7).

  Entries are deliberately plain data: building
  `AshRules.Ir.FactSchema` structs is the host bundle's job (IR
  predicate names are atoms there; the question_id strings are the
  table's spelling), and this bridge does not manufacture atoms from
  runtime strings (law 10).
  """
  @spec fact_schema_entries([AshJudgments.Registry.Question.t()]) :: [map()]
  def fact_schema_entries(questions) when is_list(questions) do
    Enum.map(questions, &fact_schema_entry/1)
  end

  defp fact_schema_entry(question) do
    entry = %{
      name: question.question_id,
      type: value_type(question),
      missing: :unknown,
      description: description_of(question)
    }

    case one_of(question) do
      nil -> entry
      options -> Map.put(entry, :one_of, options)
    end
  end

  defp value_type(%{type: AshAi.Evaluate.Noul}), do: :boolean
  defp value_type(%{type: AshAi.Evaluate.Score}), do: :number
  defp value_type(_question), do: :string

  defp one_of(question) do
    case question do
      %{type: AshAi.Evaluate.Choice, constraints: %{of: [_ | _] = options}} ->
        Enum.map(options, &to_string/1)

      %{type: AshAi.Evaluate.Choice, options: [_ | _] = options} ->
        Enum.map(options, &to_string/1)

      _ ->
        nil
    end
  end

  defp description_of(%{instructions: instructions}) when is_binary(instructions),
    do: instructions

  defp description_of(question), do: "Judged question #{question.name}"

  @doc """
  The FactBuilder: reads the current materialised facts for `subject`
  across `wanted` predicates (Registry.Question structs or predicate
  strings — one namespace) and returns the triples plus the provenance
  the direct evaluator and the ash_compliance guard path consume.

  Read-side states are honoured exactly as `AshJudgments.Query.status/4`
  reads them: a predicate only yields a triple when its current fact is
  in scope, at or above the grade floor, fresh and unexpired — `:in` and
  `:out` both yield triples; every `:unknown` reason is an OMISSION
  (missing: :unknown means the rule lattice, not the bridge, decides
  what absence means).

  Returns:

      %{
        facts:      [{subject, predicate, value}],   # value is the fact's JSON (scalar-first)
        provenance: %{predicate => %{admission_grade, admission_id, subject_state_digest, fact_id, status}},
        omissions:  [predicate]                      # consumed but yielding no triple
      }

  ## Options

  - `:scope` — the fact scope to read in.
  - `:min_grade` — the admission-grade floor (Q19); default `:grant`.
  - `:current_digests` — `%{subject => digest}` for freshness.
  - `:resource` — the facts resource; default `config :ash_judgments, :facts`.
  """
  @spec facts_for(map(), wanted(), keyword()) ::
          {:ok, %{facts: [tuple()], provenance: map(), omissions: [String.t()]}}
          | {:error, {:missing_dependency, :ash_rules}}
  def facts_for(subject, wanted, opts \\ []) do
    with :ok <- available?() do
      {predicates, questions_by_id} = normalise_wanted(wanted)
      facts_resource = facts_resource(opts)

      facts =
        Enum.flat_map(predicates, fn predicate ->
          triple(facts_resource, subject, predicate, opts)
        end)

      provenance =
        Map.new(predicates, fn predicate ->
          {predicate, provenance_for(facts_resource, subject, predicate, opts)}
        end)

      omissions =
        Enum.filter(predicates, fn predicate ->
          not Enum.any?(facts, &match?({_s, ^predicate, _v}, &1))
        end)

      _ = questions_by_id
      {:ok, %{facts: facts, provenance: provenance, omissions: omissions}}
    end
  end

  defp triple(resource, subject, predicate, opts) do
    case AshJudgments.Query.status(resource, subject, predicate, opts) do
      {verdict, fact} when verdict in [:in, :out] and is_struct(fact) ->
        [{subject, predicate, fact.value}]

      _unknown ->
        []
    end
  end

  defp provenance_for(resource, subject, predicate, opts) do
    case AshJudgments.Query.status(resource, subject, predicate, opts) do
      {verdict, fact} when verdict in [:in, :out] and is_struct(fact) ->
        %{
          status: verdict,
          admission_grade: fact.admission_grade,
          admission_id: fact.admission_id,
          subject_state_digest: fact.subject_state_digest,
          fact_id: fact.id,
          scope: fact.scope,
          value: fact.value
        }

      {:unknown, reason} ->
        %{status: :unknown, reason: reason}
    end
  end

  defp normalise_wanted(wanted) do
    predicates =
      Enum.map(wanted, fn
        %AshJudgments.Registry.Question{} = question -> question.question_id
        predicate when is_binary(predicate) -> predicate
      end)

    questions_by_id =
      wanted
      |> Enum.filter(&match?(%AshJudgments.Registry.Question{}, &1))
      |> Map.new(&{&1.question_id, &1})

    {predicates, questions_by_id}
  end

  defp facts_resource(opts) do
    opts[:resource] || Application.get_env(:ash_judgments, :facts) ||
      raise ArgumentError,
            "no facts resource configured; set config :ash_judgments, :facts to the host resource " <>
              "that includes AshJudgments.Facts.Fragment (or pass :resource in opts)"
  end

  @doc """
  The fact-snapshot hash (seams §1.5): pins the EXACT inputs a rules
  evaluation consumed, so an auditor can verify that a finding was
  produced from these facts under these rules
  (`AshRules.Ir.Bundle.content_hash/1` pins the rules; both together pin
  the finding).

  For each consumed predicate, sorted canonically:

  - a current fact contributes
    `{"predicate" => …, "subject" => …, "scope" => …, "value" => …,
      "admission_grade" => …, "admission_id" => …,
      "subject_state_digest" => …}`; and
  - an absent predicate contributes the explicit omission marker
    `{"predicate" => …, "no_current_fact" => true}` — so a fact
    appearing later changes the hash (absence is an input, not a void).

  SHA-256 over canonical JSON with the RFC §4.3 discipline (sorted keys,
  decimal strings). Probabilities are never in it — they live on
  observations reached via `admission_id`.

  `wanted` is the list of predicates the evaluation CONSUMED (questions
  or predicate strings); pass exactly what the rules touched, nothing
  more.
  """
  @spec snapshot_hash(map(), wanted(), keyword()) ::
          {:ok, String.t()} | {:error, {:missing_dependency, :ash_rules}}
  def snapshot_hash(subject, wanted, opts \\ []) do
    with :ok <- available?() do
      {predicates, _questions} = normalise_wanted(wanted)
      resource = facts_resource(opts)

      entries =
        predicates
        |> Enum.sort()
        |> Enum.map(fn predicate ->
          snapshot_entry(resource, subject, predicate, opts)
        end)

      {:ok, Canonical.digest(%{"snapshot" => entries})}
    end
  end

  defp snapshot_entry(resource, subject, predicate, opts) do
    case AshJudgments.Query.status(resource, subject, predicate, opts) do
      {verdict, fact} when verdict in [:in, :out] and is_struct(fact) ->
        %{
          "predicate" => predicate,
          "subject" => subject,
          "scope" => fact.scope,
          "value" => fact.value,
          "admission_grade" => Atom.to_string(fact.admission_grade),
          "admission_id" => fact.admission_id,
          "subject_state_digest" => fact.subject_state_digest
        }

      {:unknown, reason} ->
        %{"predicate" => predicate, "no_current_fact" => true, "reason" => Atom.to_string(reason)}
    end
  end

  @doc """
  Convenience: the current FACTS for `wanted` as the triples the direct
  evaluator consumes (`{subject, predicate_name, value}` with the
  predicate as an ATOM — the ash_rules working-memory spelling), plus the
  fact snapshot hash. The atom names must already exist (the host bundle
  declares them); unknown strings raise, by design — the bundle and the
  facts table must agree on the vocabulary.
  """
  @spec facts_and_snapshot(map(), wanted(), keyword()) ::
          {:ok,
           %{
             facts: [tuple()],
             snapshot_hash: String.t(),
             provenance: map(),
             omissions: [String.t()]
           }}
          | {:error, {:missing_dependency, :ash_rules}}
  def facts_and_snapshot(subject, wanted, opts \\ []) do
    with {:ok, %{facts: facts, provenance: provenance, omissions: omissions}} <-
           facts_for(subject, wanted, opts),
         {:ok, hash} <- snapshot_hash(subject, wanted, opts) do
      atom_facts =
        Enum.map(facts, fn {s, predicate, value} ->
          {s, String.to_existing_atom(predicate), value}
        end)

      {:ok,
       %{facts: atom_facts, snapshot_hash: hash, provenance: provenance, omissions: omissions}}
    end
  end
end
