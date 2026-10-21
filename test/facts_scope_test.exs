# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsScopeTest do
  @moduledoc """
  Issue #13: the materialiser finds the current fact by
  `(subject, predicate, scope)`, the identity the facts table enforces,
  on both fragments. An admission for one scope never revises, truncates
  or supersedes another scope's fact, and a fact in one scope never
  blocks or short-circuits an admission in another.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Facts.Materialiser

  @moduletag :db

  @subject %{"type" => "AshJudgments.Test.Note", "id" => "scope-1"}
  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"

  @scope_a %{"tenant" => "t-1", "set" => "a"}
  @scope_b %{"tenant" => "t-1", "set" => "b"}

  setup do
    # A real (non-transactional) reset of both hosts' tables, mirroring
    # facts_test.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")
    AshJudgments.TestRepo.query!("DELETE FROM test_legacy_facts")

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    :ok
  end

  for {label, host} <- [
        {"legacy fragment", AshJudgments.Test.LegacyFact},
        {"temporal fragment", AshJudgments.Test.Fact}
      ] do
    describe "#{label}" do
      @host host

      test "admissions for two scopes keep a current fact each" do
        assert materialise!(@host, scope: @scope_a, value: "urgent") == :materialised

        assert materialise!(@host, scope: @scope_b, value: "routine", holds: false) ==
                 :materialised

        facts = current_facts(@host)
        assert length(facts) == 2
        assert in_scope(facts, @scope_a).value == "urgent"
        assert in_scope(facts, @scope_b).value == "routine"
        assert in_scope(facts, @scope_b).holds == false
      end

      test "a scoped admission does not revise the subject-alone fact" do
        assert materialise!(@host, value: "urgent") == :materialised
        assert materialise!(@host, scope: @scope_a, value: "routine") == :materialised

        facts = current_facts(@host)
        assert length(facts) == 2
        assert in_scope(facts, nil).value == "urgent"
        assert in_scope(facts, @scope_a).value == "routine"
      end

      test "revising one scope leaves the other untouched" do
        :materialised = materialise!(@host, scope: @scope_a, value: "urgent")
        :materialised = materialise!(@host, scope: @scope_b, value: "routine", holds: false)
        a_before = in_scope(current_facts(@host), @scope_a)

        assert materialise!(@host, scope: @scope_b, value: "low", holds: false) == :materialised

        facts = current_facts(@host)
        assert length(facts) == 2
        a_after = in_scope(facts, @scope_a)
        assert a_after.id == a_before.id
        assert a_after.value == "urgent"
        assert a_after.admission_id == a_before.admission_id
        assert in_scope(facts, @scope_b).value == "low"
      end

      test "omitting one scope leaves the other current" do
        :materialised = materialise!(@host, scope: @scope_a, value: "urgent")
        :materialised = materialise!(@host, scope: @scope_b, value: "routine")

        assert materialise!(@host, result: :omitted, scope: @scope_b) == :superseded

        assert [fact] = current_facts(@host)
        assert fact.scope == @scope_a
        assert fact.value == "urgent"
      end

      test "omitting a scope with no fact touches no other scope's fact" do
        :materialised = materialise!(@host, scope: @scope_a, value: "urgent")

        assert materialise!(@host, result: :omitted, scope: @scope_b) == :no_prior_fact

        assert [fact] = current_facts(@host)
        assert fact.scope == @scope_a
      end

      test "a person fact in one scope does not block a grant admission in another" do
        :materialised = materialise!(@host, scope: @scope_a, grade: :person, value: "urgent")

        assert materialise!(@host, scope: @scope_b, grade: :grant, value: "routine") ==
                 :materialised

        facts = current_facts(@host)
        assert in_scope(facts, @scope_a).admission_grade == :person
        assert in_scope(facts, @scope_b).admission_grade == :grant
      end

      test "an identical fact in another scope does not make an admission unchanged" do
        :materialised = materialise!(@host, scope: @scope_a)

        assert materialise!(@host, scope: @scope_b) == :materialised
        assert length(current_facts(@host)) == 2
      end

      test "the same scope spelled with atom keys is the same scope" do
        :materialised = materialise!(@host, scope: @scope_a, value: "urgent")

        assert materialise!(@host, scope: %{tenant: "t-1", set: "a"}, value: "routine") ==
                 :materialised

        assert [fact] = current_facts(@host)
        assert fact.value == "routine"
      end
    end
  end

  describe "temporal fragment, as of a past instant" do
    @t1 ~U[2025-01-10 00:00:00Z]
    @t2 ~U[2025-06-01 00:00:00Z]
    @t3 ~U[2026-01-01 00:00:00Z]

    test "each scope keeps its own history" do
      host = AshJudgments.Test.Fact

      :materialised = materialise!(host, scope: @scope_a, value: "urgent", effective_at: @t1)

      :materialised =
        materialise!(host, scope: @scope_b, value: "routine", holds: false, effective_at: @t2)

      :materialised =
        materialise!(host, scope: @scope_b, value: "low", holds: false, effective_at: @t3)

      :superseded = materialise!(host, result: :omitted, scope: @scope_a, effective_at: @t3)

      before_b = facts_at(host, DateTime.add(@t1, 1, :hour))
      assert [%{scope: @scope_a, value: "urgent"}] = before_b

      both = facts_at(host, DateTime.add(@t2, 1, :hour))
      assert length(both) == 2
      assert in_scope(both, @scope_a).value == "urgent"
      assert in_scope(both, @scope_b).value == "routine"

      after_t3 = facts_at(host, DateTime.add(@t3, 1, :hour))
      assert [%{scope: @scope_b, value: "low"}] = after_t3
    end
  end

  defp materialise!(host, overrides) do
    decision =
      Keyword.merge(
        [
          result: :admitted,
          subject: @subject,
          predicate: @predicate,
          value: "urgent",
          holds: true,
          grade: :grant,
          admission_id: Ash.UUID.generate(),
          subject_state_digest: "sha256:" <> String.duplicate("1", 64)
        ],
        overrides
      )

    {:ok, verdict} = Materialiser.materialise(decision, resource: host)
    verdict
  end

  defp current_facts(host) do
    host
    |> Ash.Query.for_read(:for_subject, %{subject: @subject, predicate: @predicate})
    |> Ash.read!(authorize?: false)
  end

  defp facts_at(host, as_of) do
    host
    |> Ash.Query.for_read(:for_subject, %{subject: @subject, predicate: @predicate})
    |> Ash.Query.as_of(as_of)
    |> Ash.read!(authorize?: false)
  end

  defp in_scope(facts, scope) do
    case Enum.filter(facts, &(&1.scope == scope)) do
      [fact] -> fact
      other -> flunk("expected one fact in scope #{inspect(scope)}, got #{inspect(other)}")
    end
  end
end
