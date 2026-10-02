# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsTest do
  @moduledoc """
  The facts surface suite (S1-53): the materialiser truth table
  (admitted/review/omitted × grade × human override), the derived
  tri-state/status/freshness/scope/validity reads, the assess selection,
  materialisation idempotency, and the replay-equivalence property —
  materialise(clear+replay) ≡ materialise(live).
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  @moduletag :db

  # Unique-per-run subjects would be stricter, but the setup's
  # non-transactional reset already guarantees a clean table; fixed
  # subjects keep the truth tables readable.
  @subject %{"type" => "AshJudgments.Test.Note", "id" => "note-1"}
  @subject2 %{"type" => "AshJudgments.Test.Note", "id" => "note-2"}
  @subject3 %{"type" => "AshJudgments.Test.Note", "id" => "note-3"}
  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"

  setup do
    # A real (non-transactional) reset first: leftovers from debug runs
    # would otherwise leak in, and a sandboxed DELETE would roll back.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :facts, AshJudgments.Test.Fact)
    on_exit(fn -> Application.delete_env(:ash_judgments, :facts) end)
    :ok
  end

  defp decision(overrides \\ []) do
    Keyword.merge(
      [
        result: :admitted,
        subject: @subject,
        predicate: @predicate,
        value: %{"option" => "urgent"},
        holds: true,
        grade: :grant,
        admission_id: "99999999-9999-4999-8999-999999999999",
        subject_state_digest: "sha256:" <> String.duplicate("1", 64)
      ],
      overrides
    )
    |> Map.new()
  end

  defp materialise!(overrides \\ []) do
    {:ok, verdict} = AshJudgments.Facts.Materialiser.materialise(decision(overrides))
    verdict
  end

  defp current_facts do
    AshJudgments.Test.Fact
    |> Ash.Query.for_read(:for_subject, %{subject: @subject, predicate: @predicate})
    |> Ash.read!()
  end

  defp current do
    case current_facts() do
      [fact] -> fact
      [] -> nil
      facts -> List.last(facts)
    end
  end

  describe "the materialiser truth table" do
    test "admitted materialises a fact" do
      assert materialise!() == :materialised
      fact = current()

      assert fact.holds == true
      assert fact.value == %{"option" => "urgent"}
      assert fact.admission_grade == :grant
      assert fact.subject_type == "AshJudgments.Test.Note"
      assert fact.subject_id == "note-1"
      assert fact.predicate == @predicate
      assert fact.admission_id == decision()[:admission_id]
    end

    test "review writes nothing (the open task reads as unknown by absence)" do
      assert materialise!(result: :review) == :no_fact
      assert current_facts() == []
    end

    test "omitted writes no fact and supersedes a prior one (unknown, never out)" do
      assert materialise!() == :materialised
      assert materialise!(result: :omitted) == :superseded

      # The current read is empty; the superseded row stays in history.
      assert current_facts() == []

      [superseded] = Ash.read!(AshJudgments.Test.Fact)
      assert superseded.superseded_by != nil

      # Membership reads unknown after the omission.
      assert {:unknown, :no_fact} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate)
    end

    test "human entries win: a grant admission never overwrites a person fact (AC: §7.2 n2)" do
      assert materialise!(grade: :person) == :materialised
      person_fact = current()

      assert materialise!(grade: :grant, value: %{"option" => "routine"}, holds: false) ==
               :kept_person_fact

      fact = current()
      assert fact.id == person_fact.id
      assert fact.admission_grade == :person
      assert fact.value == %{"option" => "urgent"}
    end

    test "a person admission supersedes freely (the reviewer is the author of record)" do
      assert materialise!(grade: :grant) == :materialised

      assert materialise!(grade: :person, value: %{"option" => "routine"}, holds: false) ==
               :materialised

      fact = current()
      assert fact.admission_grade == :person
      assert fact.holds == false

      # The old fact is superseded, not deleted (facts are superseded,
      # never edited — ADR 0044).
      assert length(current_facts()) == 1
      history = Ash.read!(AshJudgments.Test.Fact)
      assert length(history) == 2
      assert Enum.any?(history, &(&1.superseded_by != nil))
    end

    test "materialisation is idempotent: the same admission twice leaves one row" do
      assert materialise!() == :materialised
      first = current()

      assert materialise!() == :unchanged
      second = current()

      assert second.id == first.id
      assert length(Ash.read!(AshJudgments.Test.Fact)) == 1
    end

    test "a changed value under the same admission id is materialised (content decides)" do
      assert materialise!() == :materialised
      assert materialise!(value: %{"option" => "routine"}, holds: false) == :materialised

      fact = current()
      assert fact.value == %{"option" => "routine"}
      assert fact.holds == false
    end

    test "the human-verdict path materialises a person-grade fact (§7.3 override)" do
      {:ok, :materialised} =
        AshJudgments.Facts.Materialiser.materialise_verdict(%{
          subject: @subject,
          predicate: @predicate,
          value: %{"option" => "routine"},
          holds: false,
          admission_id: "88888888-8888-4888-8888-888888888888",
          judgment_id: "77777777-7777-4777-8777-777777777777"
        })

      fact = current()
      assert fact.admission_grade == :person

      # Human entries win: the grant admission fills an absence elsewhere
      # but never touches this fact.
      assert materialise!(grade: :grant, holds: true) == :kept_person_fact
      assert current().holds == false
    end
  end

  describe "the derived reads (tri-state, status, freshness, scope, validity)" do
    test "in / out / unknown over three subjects" do
      materialise!(subject: @subject, holds: true)
      materialise!(subject: @subject2, value: %{"option" => "routine"}, holds: false)

      # note-3 has no fact at all.
      partition =
        AshJudgments.Query.tri_state(
          AshJudgments.Test.Fact,
          [@subject, @subject2, @subject3],
          @predicate
        )

      assert partition.in == [@subject]
      assert partition.out == [@subject2]
      assert [{@subject3, :no_fact}] = partition.unknown
    end

    test "unknown is never folded into in or out, and covers every reason" do
      materialise!(subject: @subject, valid_until: DateTime.add(DateTime.utc_now(), -3600))

      # Expired: unknown.
      assert {:unknown, :expired} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate)

      # Stale: the subject's current digest differs from the fact's.
      assert {:unknown, :stale} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate,
                 current_digests: %{
                   @subject => "sha256:" <> String.duplicate("9", 64)
                 }
               )

      # Below the grade floor: a grant fact under a :person floor.
      assert {:unknown, :below_grade} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate,
                 min_grade: :person,
                 current_digests: %{@subject => decision_state_digest()}
               )
    end

    test "fresh and in-scope: in, with the fact" do
      materialise!(subject: @subject)

      assert {:in, fact} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate,
                 current_digests: %{@subject => decision_state_digest()}
               )

      assert fact.value == %{"option" => "urgent"}
    end

    test "scope: a fact in another scope does not serve a scope-less read" do
      materialise!(subject: @subject, scope: %{"tenant" => "t-1"})

      assert {:unknown, :no_fact} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate)

      assert {:in, _fact} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate,
                 scope: %{"tenant" => "t-1"}
               )
    end

    test "grade floor: person facts only when the consumer demands them" do
      materialise!(subject: @subject, grade: :person)
      materialise!(subject: @subject2, grade: :grant)

      assert {:in, _} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject, @predicate,
                 min_grade: :person
               )

      assert {:unknown, :below_grade} =
               AshJudgments.Query.status(AshJudgments.Test.Fact, @subject2, @predicate,
                 min_grade: :person
               )
    end

    test "the freshness calculations on the fragment are pure reads" do
      digest = "sha256:" <> String.duplicate("1", 64)
      materialise!(subject: @subject, subject_state_digest: digest)

      [fact] = current_facts()

      refute stale?(fact, digest), "same digest: fresh"
      assert stale?(fact, "sha256:" <> String.duplicate("2", 64)), "different digest: stale"
      refute stale?(fact, nil), "unknown current digest: not provably stale"
    end

    defp stale?(fact, digest) do
      AshJudgments.Test.Fact
      |> Ash.Query.for_read(:for_subject, %{subject: @subject, predicate: @predicate})
      |> Ash.Query.load(stale?: %{current_digest: digest})
      |> Ash.read!()
      |> List.last()
      |> Map.get(:stale?)
    end

    defp decision_state_digest, do: decision()[:subject_state_digest]
  end

  describe "the assess selection" do
    test "selects the unknown subjects, bounded, with the reason" do
      materialise!(subject: @subject, holds: true)
      materialise!(subject: @subject2, holds: false)

      materialise!(
        subject: @subject3,
        valid_until: DateTime.add(DateTime.utc_now(), -3600)
      )

      selection =
        AshJudgments.Query.assess(
          AshJudgments.Test.Fact,
          [@subject, @subject2, @subject3],
          @predicate
        )

      assert {@subject3, :expired} in selection
      assert selection |> length() == 1
    end

    test "stale subjects are queued for reassessment" do
      materialise!(subject: @subject)

      selection =
        AshJudgments.Query.assess(AshJudgments.Test.Fact, [@subject], @predicate,
          current_digests: %{@subject => "sha256:" <> String.duplicate("9", 64)}
        )

      assert [{@subject, :stale}] = selection
    end

    test "the bound caps the selection" do
      subjects =
        Enum.map(1..5, fn i -> %{"type" => "AshJudgments.Test.Note", "id" => "n-#{i}"} end)

      selection =
        AshJudgments.Query.assess(AshJudgments.Test.Fact, subjects, @predicate, limit: 3)

      assert length(selection) == 3
    end

    test "the priority seam orders the selection (S1-56 hooks in here later)" do
      subjects =
        Enum.map(1..3, fn i -> %{"type" => "AshJudgments.Test.Note", "id" => "n-#{i}"} end)

      selection =
        AshJudgments.Query.assess(AshJudgments.Test.Fact, subjects, @predicate,
          priority: {__MODULE__, :priority_by_id_desc, []}
        )

      assert selection |> Enum.map(&elem(&1, 0)) |> Enum.map(& &1["id"]) == ["n-3", "n-2", "n-1"]
    end

    def priority_by_id_desc(subject, _reason) do
      String.to_integer(List.last(String.split(subject["id"], "-")))
    end
  end

  describe "the replay-equivalence property" do
    test "materialise(clear+replay) ≡ materialise(live)" do
      # A seeded admission sequence, applied live; then the same sequence
      # applied to a cleared table in the same order (the AshEvents
      # replay's job, simulated at the materialiser's level — each call's
      # inputs are what the event log recorded).
      sequence =
        for i <- 1..12 do
          subject = %{"type" => "AshJudgments.Test.Note", "id" => "note-#{rem(i, 4)}"}
          grade = if rem(i, 3) == 0, do: :person, else: :grant

          result =
            cond do
              rem(i, 5) == 0 -> :omitted
              rem(i, 7) == 0 -> :review
              true -> :admitted
            end

          holds = rem(i, 2) == 0
          value = if holds, do: %{"option" => "urgent"}, else: %{"option" => "routine"}

          %{
            # A deterministic id per decision — the caller's idempotency
            # key, exactly what the replay records and re-applies.
            id: "bbbbbbbb-1111-4111-8111-#{String.pad_leading(Integer.to_string(i), 12, "0")}",
            result: result,
            subject: subject,
            predicate: @predicate,
            value: value,
            holds: holds,
            grade: grade,
            admission_id:
              "aaaaaaaa-1111-4111-8111-#{String.pad_leading(Integer.to_string(i), 12, "0")}",
            subject_state_digest:
              "sha256:" <> String.duplicate(Integer.to_string(rem(i, 3) + 1), 64)
          }
        end

      live = run_sequence(sequence)

      # Clear everything, replay the same recorded calls in the same order.
      AshJudgments.TestRepo.query!("DELETE FROM test_facts")
      replayed = run_sequence(sequence)

      assert snapshot(replayed) == snapshot(live)
    end

    defp run_sequence(sequence) do
      Enum.each(sequence, &AshJudgments.Facts.Materialiser.materialise/1)
      snapshot_table()
    end

    defp snapshot_table do
      # The comparison set: the envelope-class columns only, sorted.
      # Calculations and timestamps are derived, not recorded state.
      AshJudgments.Test.Fact
      |> Ash.Query.select([
        :id,
        :subject,
        :subject_type,
        :subject_id,
        :predicate,
        :value,
        :holds,
        :scope,
        :subject_state_digest,
        :valid_until,
        :admission_grade,
        :admission_id,
        :superseded_by
      ])
      |> Ash.read!()
      |> Enum.map(fn fact ->
        fact
        |> Map.from_struct()
        |> Map.drop([:__spark_metadata__, :__metadata__])
        |> Map.new(fn {k, v} -> {k, normalize(v)} end)
      end)
      |> Enum.sort_by(&{&1.subject_id, &1.predicate, inspect(&1.value)})
    end

    defp snapshot(table), do: Enum.sort(table)

    defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp normalize(v) when is_map(v), do: v
    defp normalize(v), do: v
  end
end
