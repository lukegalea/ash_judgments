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
  2. **`omitted` writes no fact** (§7.2 normative 4): a current fact's
     period is truncated at `effective_at` (the predicate goes back to
     `unknown` in every consumer's read; history is preserved); no
     replacement row is written.
  3. **`review` writes nothing**: the open review task reads as
     `unknown` by absence; when the review concludes it arrives as a
     verdict or an admission.
  4. **`admitted`**: an identical fact at `effective_at` (same value,
     same state digest, grade at or above) leaves the row untouched —
     idempotent; otherwise the period splits at `effective_at` and the
     revision carries the admission's grade and id for provenance.

  **Two modes, dispatched on the host** (AST-147): a host whose facts
  resource is TEMPORAL (includes `AshJudgments.Facts.TemporalFragment`) is
  served by the temporal protocol — writes split or truncate periods at
  the admission's `effective_at` (`decision[:effective_at]`, now by
  default), and the read-then-supersede-then-create dance is replaced by
  the database's lock-and-recheck split protocol
  (`AshPostgres.Temporal.WriteConflict` surfaces after the engine's
  bounded retries; nothing is written by a losing attempt). Legacy hosts
  (the `Facts.Fragment` shape) keep the supersede-then-create path
  unchanged. Division of labor: **temporal = how rows version; the
  materialiser = why rows change**.

  Every write is a fragment action that accepts its fields as input and
  computes only pure derived fields — replay-safe like the ledger (the
  materialiser's own calls are deterministic in the subject, predicate
  and decision, so replaying the admission sequence reproduces the same
  final table — and, with the `as_of` capture, the same PERIODS: the
  property test pins `materialise(clear+replay) ≡ materialise(live)`).
  """

  @moduledoc since: "0.1.0"

  @doc """
  Materialises one admission decision onto the configured facts resource.

  `decision` fields: `result` (`:admitted | :review | :omitted`), the
  `subject` (composite map), `predicate` (string; the question id for
  judged predicates), `value` (the fact's JSON object), `holds` (the
  membership reading of the value), `grade` (`:person | :grant`),
  optional `scope` (map), `subject_state_digest`, `valid_until`,
  `admission_id`, `id` (a deterministic id makes the write an
  idempotency key for the caller) and — on temporal hosts —
  `effective_at` (the instant the fact takes effect; now by default).

  Returns `{:ok, verdict}` where the verdict is one of `:materialised`,
  `:unchanged`, `:kept_person_fact`, `:superseded`, `:no_fact` — plain
  data the caller can log or audit.
  """
  @spec materialise(map() | keyword(), keyword()) :: {:ok, atom()} | {:error, term()}
  def materialise(decision, opts \\ []) do
    decision = Map.new(decision)

    with :ok <- check_predicate(decision) do
      resource = facts_resource(opts)
      grade = decision[:grade] || :grant

      if temporal?(resource) do
        temporal_materialise(resource, decision, grade)
      else
        legacy_materialise(resource, decision, grade)
      end
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

  ## Dispatch

  defp temporal?(resource) do
    Ash.Resource.Info.temporal?(resource)
  end

  ## The legacy path (Facts.Fragment hosts) — unchanged from 0.1.

  defp legacy_materialise(resource, decision, grade) do
    current = current_fact(resource, decision)

    legacy_decide(resource, decision, current, grade)
  end

  defp legacy_decide(resource, decision, current, grade) do
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
        legacy_admitted(resource, decision, current, grade)

      true ->
        {:error,
         ArgumentError.exception(
           "unknown admission result #{inspect(decision[:result])} — expected :admitted, :review or :omitted"
         )}
    end
  end

  defp legacy_admitted(resource, decision, current, grade) do
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

      changeset =
        Ash.Changeset.for_create(
          resource,
          :materialise,
          materialise_inputs(decision, grade)
        )

      changeset
      |> Ash.create!()

      AshJudgments.Telemetry.materialised(%{
        predicate: decision[:predicate],
        verdict: :materialised,
        grade: grade,
        region: AshJudgments.Telemetry.current_region()
      })

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

  ## The temporal path (TemporalFragment hosts) — AST-147.

  defp temporal_materialise(resource, decision, grade) do
    as_of = effective_at(decision)
    current = temporal_current(resource, decision, as_of)

    temporal_decide(resource, decision, current, grade, as_of)
  end

  defp effective_at(decision) do
    # §7.2: the admission carries the instant its fact takes effect.
    # Backdated `effective_at` reconstructs history retroactively; the
    # default is now.
    decision[:effective_at] || DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp temporal_decide(resource, decision, current, grade, as_of) do
    cond do
      current && current.admission_grade == :person && grade == :grant ->
        # §7.2 normative 2: unchanged at any instant — an automatic
        # admission never overwrites or lowers a person-admitted fact.
        {:ok, :kept_person_fact}

      decision[:result] == :omitted ->
        temporal_truncate(resource, current, decision, as_of)

      decision[:result] == :review ->
        {:ok, :no_fact}

      decision[:result] == :admitted ->
        temporal_admitted(resource, decision, current, grade, as_of)

      true ->
        {:error,
         ArgumentError.exception(
           "unknown admission result #{inspect(decision[:result])} — expected :admitted, :review or :omitted"
         )}
    end
  end

  defp temporal_admitted(resource, decision, current, grade, as_of) do
    identical? =
      current != nil and
        current.value == decision[:value] and
        current.holds == decision[:holds] and
        current.subject_state_digest == decision[:subject_state_digest] and
        AshJudgments.Facts.grade_at_least?(grade_of(current), grade)

    cond do
      identical? ->
        {:ok, :unchanged}

      current ->
        current
        |> Ash.Changeset.for_update(
          :revise,
          revise_inputs(decision, grade),
          as_of: as_of,
          authorize?: false
        )
        |> Ash.update!()

        AshJudgments.Telemetry.materialised(%{
          predicate: decision[:predicate],
          verdict: :materialised,
          grade: grade,
          region: AshJudgments.Telemetry.current_region()
        })

        {:ok, :materialised}

      true ->
        resource
        |> Ash.Changeset.for_create(
          :materialise,
          materialise_inputs(decision, grade),
          as_of: as_of,
          authorize?: false
        )
        |> Ash.create!()

        AshJudgments.Telemetry.materialised(%{
          predicate: decision[:predicate],
          verdict: :materialised,
          grade: grade,
          region: AshJudgments.Telemetry.current_region()
        })

        {:ok, :materialised}
    end
  end

  defp temporal_truncate(_resource, nil, _decision, _as_of), do: {:ok, :no_prior_fact}

  defp temporal_truncate(resource, current, _decision, as_of) do
    # §7.2 normative 4: omission supersedes with no replacement — on a
    # temporal resource this TRUNCATES the period at as_of (history is
    # preserved; the predicate returns to unknown from that instant).
    current
    |> Ash.Changeset.for_destroy(:truncate, %{}, as_of: as_of, authorize?: false)
    |> Ash.destroy!(authorize?: false)

    _ = resource

    {:ok, :superseded}
  end

  defp temporal_current(resource, decision, as_of) do
    resource
    |> Ash.Query.for_read(:for_subject, %{
      subject: decision[:subject],
      predicate: decision[:predicate]
    })
    |> Ash.Query.as_of(as_of)
    |> Ash.read!()
    |> case do
      [fact] -> fact
      [] -> nil
      facts -> List.last(facts)
    end
  end

  ## Shared internals

  defp check_predicate(decision) do
    if AshJudgments.Exploration.exploratory?(decision[:predicate]) do
      {:error,
       AshJudgments.Exploration.ExploratoryRefused.exception(
         question_id: decision[:predicate],
         surface: "the fact materialiser"
       )}
    else
      :ok
    end
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

  defp revise_inputs(decision, grade) do
    decision
    |> Map.take([
      :value,
      :holds,
      :subject_state_digest,
      :valid_until,
      :admission_id
    ])
    |> Map.put(:admission_grade, grade)
  end

  defp current_fact(resource, decision) do
    resource
    |> Ash.Query.for_read(:for_subject, %{
      subject: decision[:subject],
      predicate: decision[:predicate]
    })
    |> Ash.read!()
    |> case do
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
