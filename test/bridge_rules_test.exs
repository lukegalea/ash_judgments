# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.BridgeRulesTest do
  @moduledoc """
  The ash_rules bridge suite (AST-93): fact-schema entries with
  escalate-means-omission, the FactBuilder over the materialised facts
  table, the snapshot hash (inputs pinned, omission markers included),
  the escalate-means-omission obligations, and the S1-54 equivalence
  cross-check — `AshRules.Evaluator.Set.membership/4` over this facts
  resource matches `AshJudgments.Query.tri_state/4` for the same
  subjects and questions.
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  alias AshJudgments.Bridge.Rules
  alias AshJudgments.Query

  @moduletag :db

  @subject %{"type" => "AshJudgments.Test.Note", "id" => "note-1"}
  @subject2 %{"type" => "AshJudgments.Test.Note", "id" => "note-2"}
  @subject3 %{"type" => "AshJudgments.Test.Note", "id" => "note-3"}

  # A crisp, test-owned predicate namespace (§7.4: one namespace with the
  # judged question ids — the crisp spelling is legal and keeps the IR
  # atom names host-declared).
  @predicate "triage_urgent"
  @ir_predicate_name :triage_urgent
  @grade_floor :grant
  @observation_id "88888888-8888-4888-8888-888888888888"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_facts) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :facts, AshJudgments.Test.Fact)
    on_exit(fn -> Application.delete_env(:ash_judgments, :facts) end)
    :ok
  end

  defp materialise!(overrides \\ []) do
    decision =
      Keyword.merge(
        [
          result: :admitted,
          subject: @subject,
          predicate: @predicate,
          value: true,
          holds: true,
          grade: :grant,
          admission_id: "99999999-9999-4999-8999-999999999999",
          id: @observation_id,
          subject_state_digest: "sha256:" <> String.duplicate("1", 64)
        ],
        overrides
      )
      |> Map.new()

    case AshJudgments.Facts.Materialiser.materialise(decision) do
      {:ok, verdict} -> {verdict, decision}
      {:error, error} -> raise error
    end
  end

  defp base_decision do
    %{
      result: :admitted,
      subject: @subject,
      predicate: @predicate,
      value: true,
      holds: true,
      grade: :grant,
      admission_id: "99999999-9999-4999-8999-999999999999",
      subject_state_digest: "sha256:" <> String.duplicate("1", 64)
    }
  end

  describe "fact_schema_entries/1" do
    test "judged questions map to entries with escalate-means-omission" do
      questions =
        AshJudgments.Registry.questions(AshJudgments.Test.Note) ++
          AshJudgments.Registry.questions(AshJudgments.Test.Appointment)

      entries = Rules.fact_schema_entries(questions)

      assert length(entries) == length(questions)

      for {question, entry} <- Enum.zip(questions, entries) do
        assert entry.name == question.question_id
        assert entry.missing == :unknown
      end

      by_id = Map.new(entries, &{&1.name, &1})

      noul = by_id["judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up"]
      assert noul.type == :boolean

      choice = by_id["judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"]
      assert choice.type == :string
      # The option vocabulary rides one_of (the abstain option included).
      assert "urgent" in choice.one_of
      assert "insufficient" in choice.one_of
    end

    test "type per answer kind: choice → string, noul → boolean" do
      entries =
        Rules.fact_schema_entries(
          AshJudgments.Registry.questions(AshJudgments.Test.Note) ++
            AshJudgments.Registry.questions(AshJudgments.Test.Appointment)
        )

      types = Map.new(entries, &{&1.name, &1.type})

      assert types["judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up"] == :boolean

      assert types["judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"] ==
               :string
    end
  end

  describe "facts_for/3 — the FactBuilder" do
    test "admitted in-fact yields a triple with provenance" do
      materialise!(holds: true, value: true)

      assert {:ok, %{facts: [triple], provenance: provenance, omissions: []}} =
               Rules.facts_for(@subject, [@predicate], min_grade: @grade_floor)

      assert triple == {@subject, @predicate, true}

      prov = provenance[@predicate]
      assert prov.status == :in
      assert prov.admission_grade == :grant
      assert prov.admission_id == base_decision()[:admission_id]
      assert prov.subject_state_digest == base_decision()[:subject_state_digest]
      assert prov.fact_id
    end

    test "an out-fact yields its triple too (facts decide, both directions)" do
      materialise!(holds: false, value: false)

      assert {:ok, %{facts: [{@subject, @predicate, false}]}} =
               Rules.facts_for(@subject, [@predicate], min_grade: @grade_floor)
    end

    test "no fact is an omission — escalate means omission, never false" do
      assert {:ok, %{facts: [], omissions: [@predicate], provenance: provenance}} =
               Rules.facts_for(@subject, [@predicate], min_grade: @grade_floor)

      assert provenance[@predicate].status == :unknown
      assert provenance[@predicate].reason == :no_fact
    end

    test "stale and expired facts are omissions (read-side states)" do
      materialise!(valid_until: DateTime.add(DateTime.utc_now(), -3600))

      assert {:ok, %{facts: [], omissions: [@predicate]}} =
               Rules.facts_for(@subject, [@predicate], min_grade: @grade_floor)
    end

    test "grade floor: grant facts are omissions under a :person floor" do
      materialise!(grade: :grant)

      assert {:ok, %{facts: [], omissions: [@predicate]}} =
               Rules.facts_for(@subject, [@predicate], min_grade: :person)
    end
  end

  describe "snapshot_hash/3" do
    test "pins the consumed facts: same facts, same hash" do
      materialise!(holds: true)
      {:ok, hash1} = Rules.snapshot_hash(@subject, [@predicate], min_grade: @grade_floor)
      {:ok, hash2} = Rules.snapshot_hash(@subject, [@predicate], min_grade: @grade_floor)

      assert hash1 == hash2
      assert String.starts_with?(hash1, "sha256:")
    end

    test "an absent predicate contributes the omission marker — a fact appearing later changes the hash" do
      {:ok, absent} = Rules.snapshot_hash(@subject, [@predicate], min_grade: @grade_floor)

      materialise!(holds: true)

      {:ok, present} = Rules.snapshot_hash(@subject, [@predicate], min_grade: @grade_floor)

      refute absent == present
    end

    test "a value change changes the hash; probabilities never enter" do
      materialise!(holds: true, value: true)
      {:ok, first} = Rules.snapshot_hash(@subject, [@predicate], min_grade: @grade_floor)

      # A superseding decision, its own observation id (facts are
      # superseded, never edited).
      materialise!(value: false, holds: false, id: "66666666-6666-4666-8666-666666666666")
      {:ok, second} = Rules.snapshot_hash(@subject, [@predicate], min_grade: @grade_floor)

      refute first == second
    end

    test "grade floor participates: a grant fact under a :person floor hashes as an omission" do
      materialise!(grade: :grant)
      {:ok, with_grant} = Rules.snapshot_hash(@subject, [@predicate], min_grade: :grant)

      {:ok, under_person_floor} = Rules.snapshot_hash(@subject, [@predicate], min_grade: :person)

      assert with_grant != under_person_floor
      # The omission marker is present in the second digest's preimage —
      # verified behaviourally: nothing but the floor changed.
    end
  end

  describe "escalate-means-omission obligations" do
    test "review writes nothing; the predicate stays unknown" do
      assert {verdict, _} = materialise!(result: :review)
      assert verdict == :no_fact
      assert current_facts() == []

      assert {:unknown, :no_fact} =
               Query.status(AshJudgments.Test.Fact, @subject, @predicate, min_grade: @grade_floor)
    end

    test "omit supersedes a current fact — the predicate returns to unknown for every consumer" do
      assert materialise!() |> elem(0) == :materialised

      # The banding→admission pipeline's omit path:
      materialise!(result: :omitted)

      assert {:unknown, :no_fact} =
               Query.status(AshJudgments.Test.Fact, @subject, @predicate, min_grade: @grade_floor)

      assert {:ok, %{facts: []}} =
               Rules.facts_for(@subject, [@predicate], min_grade: @grade_floor)
    end

    test "the materialiser never deletes stale or expired facts — only a superseding decision moves them" do
      # A stale fact (the subject's digest moved past it).
      {verdict, decision} = materialise!()
      assert verdict == :materialised

      rows_before = Ash.read!(AshJudgments.Test.Fact) |> length()
      assert rows_before == 1

      # Time passes; nothing writes. The fact is stale on the read side…
      stale_read =
        Query.status(AshJudgments.Test.Fact, @subject, @predicate,
          min_grade: @grade_floor,
          current_digests: %{@subject => "sha256:" <> String.duplicate("9", 64)}
        )

      assert {:unknown, :stale} = stale_read

      # …and the row is STILL THERE, unsuperseded: staleness never moves a
      # fact. Even an omitted decision supersedes (a superseding decision);
      # there is no delete path at all.
      materialise!(result: :omitted)

      history = Ash.read!(AshJudgments.Test.Fact)
      assert length(history) == rows_before

      # The original row survives in history, superseded but not deleted.
      superseded = Enum.find(history, &(&1.id == @observation_id))
      assert superseded != nil
    end

    defp current_facts do
      AshJudgments.Test.Fact
      |> Ash.Query.for_read(:for_subject, %{subject: @subject, predicate: @predicate})
      |> Ash.read!()
    end
  end

  describe "the S1-54 equivalence cross-check" do
    test "Set.membership over the facts resource matches Query.tri_state (grade floor :grant)" do
      # Three subjects: in, out, and absent (unknown).
      materialise!(subject: @subject, holds: true)

      materialise!(
        subject: @subject2,
        holds: false,
        value: false,
        id: "55555555-5555-4555-8555-555555555555"
      )

      # @subject3: no fact at all.

      subjects = [@subject, @subject2, @subject3]

      # The package's derived read.
      %{in: q_in, out: q_out, unknown: q_unknown} =
        Query.tri_state(AshJudgments.Test.Fact, subjects, @predicate, min_grade: @grade_floor)

      # The set evaluator over the same facts resource. The IR predicate
      # name must be an atom whose string spelling matches the stored
      # predicate (S1-54's probe_query); the test declares the atom via
      # String.to_atom on a TEST-OWNED constant (bounded vocabulary).
      # The IR predicate name must be an atom whose string spelling matches
      # the stored predicate. The atom is created ONCE per VM at compile
      # time from this module attribute (a compile-time constant — the law
      # 10 exception).
      name = @ir_predicate_name

      schema =
        AshRules.Ir.FactSchema.new([
          AshRules.Ir.Fact.new(name, :boolean, missing: :unknown)
        ])

      schema =
        AshRules.Ir.FactSchema.new([
          AshRules.Ir.Fact.new(name, :boolean, missing: :unknown)
        ])

      subject_var = struct(AshRules.Ir.Var, name: :subject)

      predicate = AshRules.Ir.Predicate.new(:has, subject_var, name, true)

      {:ok, membership} =
        AshRules.Evaluator.Set.membership(schema, [predicate], AshJudgments.Test.Fact, [])

      assert membership.in == Enum.sort(q_in)
      assert membership.out == Enum.sort(q_out)

      # unknown: same partition. The set evaluator's universe is the
      # subjects present in the fact table (S1-54: absent subjects are the
      # host's join), so the unknown partition covers exactly the subjects
      # with rows that are not in or out — here, none (only two rows exist,
      # both decided). The package's tri_state additionally covers the
      # subject with no facts at all, which is precisely the documented
      # difference.
      set_unknown = membership.unknown
      package_unknown = q_unknown

      table_subjects = AshJudgments.Test.Fact |> Ash.read!() |> Enum.map(& &1.subject)

      # The evaluator's unknown ∩ the table's subjects must equal the
      # package's unknown subjects ∩ the table's subjects — both empty
      # here.
      assert Enum.filter(set_unknown, &(&1 in table_subjects)) ==
               Enum.filter(Enum.map(package_unknown, &elem(&1, 0)), &(&1 in table_subjects))

      # The set evaluator's universe is the subjects present in the fact
      # table (S1-54: absent subjects are the host's join), so @subject3 —
      # with no facts at all — never enters its partitions. The package's
      # tri_state DOES cover it: the host-join case is exactly what
      # Query.status/4 answers for consumers that need it.
      refute @subject3 in set_unknown
      assert {@subject3, :no_fact} in package_unknown
    end
  end

  describe "availability" do
    test "degrades to the structured error when ash_rules is off the path" do
      # The dep IS loaded in this repository; the off-path is exercised by
      # purging the marker (same technique as availability_off_test).
      dir = ebin_dir!(AshRules)
      :code.purge(AshRules)
      :code.delete(AshRules)
      :code.del_path(dir)

      try do
        assert {:error, {:missing_dependency, :ash_rules}} = Rules.available?()

        assert {:error, {:missing_dependency, :ash_rules}} =
                 Rules.facts_for(@subject, [@predicate])

        assert {:error, {:missing_dependency, :ash_rules}} =
                 Rules.snapshot_hash(@subject, [@predicate])
      after
        :code.add_path(dir)
        {:module, AshRules} = Code.ensure_loaded(AshRules)
      end
    end

    defp ebin_dir!(module) do
      beam = Atom.to_charlist(module) ++ ~c".beam"

      case :code.where_is_file(beam) do
        :non_existing -> flunk("#{inspect(module)} beam not on the code path")
        full -> full |> List.to_string() |> Path.dirname() |> to_charlist()
      end
    end
  end
end
