# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.Materialiser do
  @moduledoc """
  The materialisation write path: admissions and human verdicts keep the
  facts table in sync (S1-53; RFC §7.2/§7.3/§7.4).

  The rules, in evaluation order — each decision is recorded, never
  re-derived (law 2: the caller passes the admission's result; nothing
  here bands, judges or consults a model):

  1. **Human entries win** (§7.2 normative 2): an automation-grade
     admission never overwrites or lowers a person-admitted current fact.
     It may only fill an absence. A person admission supersedes freely.
  2. **`omitted` writes no fact** (§7.2 normative 4): a current fact is
     superseded (the predicate goes back to `unknown` in every
     consumer's read); no replacement row is written.
  3. **`review` writes nothing**: the open review task reads as
     `unknown` by absence; when the review concludes it arrives as a
     verdict or an admission.
  4. **`admitted`**: an identical current fact (same value, same state
     digest, grade at or above) leaves the row untouched — idempotent;
     otherwise the current fact is superseded and a replacement is
     written, carrying the admission's grade and id for provenance.

  Every write is a fragment action that accepts its fields as input and
  computes only pure derived fields — replay-safe like the ledger (the
  materialiser's own calls are deterministic in the subject, predicate
  and decision, so replaying the admission sequence reproduces the same
  final table: the property test pins `materialise(clear+replay) ≡
  materialise(live)`).
  """

  @moduledoc since: "0.1.0"

  @doc """
  Materialises one admission decision onto the configured facts resource.

  `decision` fields: `result` (`:admitted | :review | :omitted`), the
  `subject` (composite map), `predicate` (string; the question id for
  judged predicates), `value` (the fact's JSON object), `holds` (the
  membership reading of the value), `grade` (`:person | :grant`),
  optional `scope` (map), `subject_state_digest`, `valid_until`,
  `admission_id` and `id` (a deterministic id makes the write an
  idempotency key for the caller).

  Returns `{:ok, verdict}` where the verdict is one of `:materialised`,
  `:unchanged`, `:kept_person_fact`, `:superseded`, `:no_fact` — plain
  data the caller can log or audit.
  """
  @spec materialise(map(), keyword()) :: {:ok, atom()} | {:error, term()}
  def materialise(decision, opts \\ []) when is_map(decision) do
    resource = facts_resource(opts)
    grade = decision[:grade] || :grant
    current = current_fact(resource, decision)

    cond do
      current && current.admission_grade == :person && grade == :grant ->
        # §7.2 normative 2: an automatic admission never overwrites or
        # lowers a fact a person entered. It may only fill an absence.
        {:ok, :kept_person_fact}

      decision[:result] == :omitted ->
        supersede_current(current, decision)

      decision[:result] == :review ->
        # The open review task reads as unknown by absence; nothing is
        # written. Its conclusion arrives as a verdict or an admission.
        {:ok, :no_fact}

      decision[:result] == :admitted ->
        admitted(resource, decision, current, grade)

      true ->
        {:error,
         ArgumentError.exception(
           "unknown admission result #{inspect(decision[:result])} — expected :admitted, :review or :omitted"
         )}
    end
  end

  @doc """
  Materialises a human verdict (RFC §7.3) as a **person-grade** fact:
  the reviewer is the author of record, so the verdict outranks and
  supersedes any automation-grade fact for the same predicate.

  `verdict` fields: `judgment_id` (the observation's id, carried as the
  admission provenance), the `subject`, `predicate`, `human_value` (the
  fact's JSON object), `holds`, and the optional `scope`,
  `subject_state_digest`, `valid_until`, `admission_id`, `id`.
  """
  @spec materialise_verdict(map(), keyword()) :: {:ok, atom()} | {:error, term()}
  def materialise_verdict(verdict, opts \\ []) when is_map(verdict) do
    decision =
      verdict
      |> Map.new(fn {k, v} -> {k, v} end)
      |> Map.put(:result, :admitted)
      |> Map.put(:grade, :person)

    materialise(decision, opts)
  end

  ## Internals

  defp admitted(resource, decision, current, grade) do
    identical? =
      current != nil and
        current.value == decision[:value] and
        current.holds == decision[:holds] and
        current.subject_state_digest == decision[:subject_state_digest] and
        AshJudgments.Facts.grade_at_least?(grade_of(current), grade)

    if identical? do
      {:ok, :unchanged}
    else
      {:ok, _} = supersede_current(current, decision)

      resource
      |> Ash.Changeset.for_create(:materialise, materialise_inputs(decision, grade))
      |> Ash.create!()

      {:ok, :materialised}
    end
  end

  defp supersede_current(nil, _decision), do: {:ok, :no_prior_fact}

  defp supersede_current(current, decision) do
    current
    |> Ash.Changeset.for_update(:supersede, %{superseded_by: superseder_id(decision)})
    |> Ash.update!()

    {:ok, :superseded}
  end

  # The replacing fact's own id when one is given, else the admission's id
  # — the id of whatever took this fact's place.
  defp superseder_id(decision),
    do: decision[:id] || decision[:admission_id] || Ash.UUID.generate()

  defp grade_of(current), do: current.admission_grade

  defp materialise_inputs(decision, grade) do
    decision
    |> Map.take([
      :id,
      :subject,
      :predicate,
      :value,
      :holds,
      :scope,
      :subject_state_digest,
      :valid_until,
      :admission_id
    ])
    |> Map.put(:admission_grade, grade)
  end

  defp current_fact(resource, decision) do
    IO.puts(
      :stderr,
      "DBG current_fact subject=#{inspect(decision[:subject])} pred=#{inspect(decision[:predicate])}"
    )

    found =
      resource
      |> Ash.Query.for_read(:for_subject, %{
        subject: decision[:subject],
        predicate: decision[:predicate]
      })
      |> Ash.read!()

    IO.puts(:stderr, "DBG current_fact found=#{length(found)}")
    IO.puts(:stderr, "DBG all rows=#{length(Ash.read!(resource))}")

    case found do
      [fact] -> fact
      [] -> nil
      facts -> List.last(facts)
    end
  end

  defp facts_resource(opts) do
    opts[:resource] || Application.get_env(:ash_judgments, :facts) ||
      raise ArgumentError,
            "no facts resource configured; set config :ash_judgments, :facts to the host resource " <>
              "that includes AshJudgments.Facts.Fragment (or pass :resource in opts)"
  end
end
