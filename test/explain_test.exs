# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.ExplainTest do
  @moduledoc """
  `AshJudgments.Explain.fact/3`: the chain fact, banding, decision evaluation, observations and atoms on the
  `ash_provenance` contract, and the typed gap each link degrades to. Pure: the records are plain maps.
  """

  use ExUnit.Case, async: true

  alias AshJudgments.Explain
  alias AshProvenance.{Address, Explanation, Gap, Step}

  @base "https://example.test/aj"
  @after_cutoff ~U[2026-10-01 00:00:00Z]
  @before_cutoff ~U[2026-09-01 00:00:00Z]

  defp ids do
    %{
      fact: Ash.UUID.generate(),
      banding: Ash.UUID.generate(),
      evaluation: Ash.UUID.generate(),
      observation: Ash.UUID.generate(),
      atoms: [Ash.UUID.generate(), Ash.UUID.generate()]
    }
  end

  defp scenario(overrides \\ %{}) do
    i = ids()

    fact = %{id: i.fact, admission_id: i.banding, admission_grade: :grant}

    banding = %{
      id: i.banding,
      band: :admit,
      reason_code: "high_confidence",
      matched_rule_ids: ["rule-1"],
      band_table: %{
        "definition_key" => "triage_band",
        "definition_version" => 3,
        "content_hash" => String.duplicate("ab", 32)
      },
      decision_evaluation_id: i.evaluation,
      observation_ids: [i.observation],
      mode: :live,
      banded_at: @after_cutoff
    }

    evaluation = %{
      id: i.evaluation,
      definition_key: "triage_band",
      definition_version: 3,
      matched_rule_ids: ["rule-1"],
      hit_policy: "UNIQUE",
      error: nil,
      inserted_at: @after_cutoff
    }

    observation = %{
      id: i.observation,
      question_id: "triage_urgency",
      question_version: 2,
      question_hash: String.duplicate("cd", 32),
      answer_kind: :choice,
      mode: :live,
      atom_ids: i.atoms
    }

    base = %{
      fact: fact,
      links: %{banding: banding, evaluation: evaluation, observations: [observation]},
      ids: i
    }

    Map.merge(base, overrides)
  end

  defp explain(%{fact: fact, links: links}, opts \\ []) do
    {:ok, explanation} = Explain.fact(fact, links, Keyword.merge([base: @base], opts))
    explanation
  end

  defp relations(%Explanation{steps: steps}), do: Enum.map(steps, & &1.relation)
  defp gap_kinds(%Explanation{gaps: gaps}), do: Enum.map(gaps, & &1.kind)

  describe "the whole chain" do
    test "fact, band table, evaluation, ledger and atoms" do
      s = scenario()
      e = explain(s)

      assert e.subject ==
               Address.new!(base: @base, type: "fact", id: s.ids.fact, attribute: "value")

      assert relations(e) == [
               :was_generated_by,
               :used,
               :was_derived_from,
               :was_derived_from,
               :was_derived_from
             ]

      assert e.gaps == []
      assert e.bounds == %{max_depth: 3, max_steps: 200, depth: 3, step_count: 5, cut?: false}

      [generated, used, observed | atoms] = e.steps

      assert generated.activity == "banding:" <> s.ids.banding
      assert AshProvenance.Plan.format(generated.plan) == "triage_band@3#abababab"
      assert generated.execution_context == :live
      assert generated.summary =~ "band admit"
      assert generated.summary =~ "rule-1"

      assert used.entity ==
               Address.new!(base: @base, type: "decision_evaluation", id: s.ids.evaluation)

      assert used.activity == generated.activity
      assert used.summary == "rules matched: rule-1 (hit policy UNIQUE)"

      assert observed.antecedent ==
               Address.new!(base: @base, type: "judgment_observation", id: s.ids.observation)

      assert AshProvenance.Plan.format(observed.plan) == "triage_urgency@2#cdcdcdcd"

      assert Enum.map(atoms, & &1.antecedent.id) == s.ids.atoms
      assert Enum.all?(atoms, &(&1.entity == observed.antecedent))
    end

    test "the atoms option supplies the atom hop, and its gaps are kept" do
      s = scenario()

      atoms = fn observation, cited ->
        assert observation.type == "judgment_observation"
        assert cited == s.ids.atoms

        %{steps: [], gaps: [Gap.new!(kind: :erased, of: observation, summary: "atom erased")]}
      end

      e = explain(s, atoms: atoms)

      assert relations(e) == [:was_generated_by, :used, :was_derived_from]
      assert [%Gap{kind: :erased}] = e.gaps
      assert e.bounds.depth == 3
    end

    test "type tokens can be overridden" do
      e = explain(scenario(), types: [fact: "system_one_fact", banding: "s1_banding"])

      assert e.subject.type == "system_one_fact"
      assert hd(e.steps).activity =~ ~r/\As1_banding:/
    end

    test "a longer chain is cut at max_steps and says so" do
      e = explain(scenario(), max_steps: 2)

      assert length(e.steps) == 2
      assert %{step_count: 2, max_steps: 2, cut?: true} = e.bounds
    end
  end

  describe "matched_rule_ids classification" do
    defp with_evaluation(changes) do
      s = scenario()
      put_in(s, [:links, :evaluation], Map.merge(s.links.evaluation, changes))
    end

    test "[] with a hit policy is a real answer: no rule matched" do
      e = explain(with_evaluation(%{matched_rule_ids: []}))

      assert e.gaps == []
      assert Enum.at(e.steps, 1).summary == "no rule matched (hit policy UNIQUE)"
    end

    test "[] with an error is a :failed gap, and the error text is not copied" do
      e =
        explain(
          with_evaluation(%{matched_rule_ids: [], error: %{"message" => "secret input 4111"}})
        )

      assert gap_kinds(e) == [:failed]
      refute inspect(e) =~ "4111"
      assert Enum.at(e.steps, 1).summary == "the evaluation failed"
    end

    test "a nil hit policy is :not_recorded" do
      e = explain(with_evaluation(%{matched_rule_ids: [], hit_policy: nil}))

      assert gap_kinds(e) == [:not_recorded]
    end

    test "a row from before 2026-09-23 is :not_recorded even with a hit policy" do
      e = explain(with_evaluation(%{matched_rule_ids: [], inserted_at: @before_cutoff}))

      assert gap_kinds(e) == [:not_recorded]
    end

    test "many matched rules are listed up to a bound and the summary stays within 280 bytes" do
      ids = Enum.map(1..40, &"a-very-long-rule-identifier-number-#{&1}")
      e = explain(with_evaluation(%{matched_rule_ids: ids}))

      summary = Enum.at(e.steps, 1).summary
      assert byte_size(summary) <= 280
      assert summary =~ ~r/\(\+\d+ more\) \(hit policy UNIQUE\)\z/
    end
  end

  describe "a link that is not there" do
    test "no admission_id (a replayed or directly entered fact) is :not_recorded and has no steps" do
      s = scenario()
      e = explain(%{s | fact: %{s.fact | admission_id: nil}})

      assert e.steps == []
      assert [%Gap{kind: :not_recorded, of: subject}] = e.gaps
      assert subject == e.subject
      assert e.bounds.depth == 0
    end

    test "a banding that is not found, or is another row, is :not_recorded" do
      s = scenario()

      for banding <- [nil, %{s.links.banding | id: Ash.UUID.generate()}] do
        e = explain(put_in(s, [:links, :banding], banding))
        assert e.steps == []
        assert gap_kinds(e) == [:not_recorded]
      end
    end

    test "an unreadable banding is an :unreadable gap with nothing else" do
      e = explain(put_in(scenario(), [:links, :banding], :unreadable))

      assert e.steps == []
      assert e.gaps == [Gap.new!(kind: :unreadable, of: e.subject)]
    end

    test "an unreadable evaluation keeps the banding and observations, and names no evaluation id" do
      s = put_in(scenario(), [:links, :evaluation], :unreadable)
      e = explain(s)

      assert relations(e) == [
               :was_generated_by,
               :was_derived_from,
               :was_derived_from,
               :was_derived_from
             ]

      assert e.gaps == [Gap.new!(kind: :unreadable, of: e.subject)]
      refute inspect(e.gaps) =~ s.ids.evaluation
    end

    test "a missing evaluation is :not_recorded" do
      e = explain(put_in(scenario(), [:links, :evaluation], nil))

      assert gap_kinds(e) == [:not_recorded]
      refute :used in relations(e)
    end

    test "an evaluation that is a different row from the one the banding names is :not_recorded" do
      s = scenario()

      e =
        explain(put_in(s, [:links, :evaluation], %{s.links.evaluation | id: Ash.UUID.generate()}))

      assert gap_kinds(e) == [:not_recorded]
    end

    test "unreadable observations give one :unreadable gap per cited observation, no ids" do
      s = scenario()
      second = Ash.UUID.generate()
      s = put_in(s, [:links, :banding, :observation_ids], [s.ids.observation, second])
      e = explain(put_in(s, [:links, :observations], :unreadable))

      assert [%Gap{kind: :unreadable}, %Gap{kind: :unreadable}] = e.gaps
      refute inspect(e.gaps) =~ second
    end

    test "an observation missing from the list is :not_recorded and the others still explain" do
      s = scenario()
      missing = Ash.UUID.generate()
      s = put_in(s, [:links, :banding, :observation_ids], [missing, s.ids.observation])
      e = explain(s)

      assert gap_kinds(e) == [:not_recorded]

      assert Enum.any?(
               e.steps,
               &match?(%Step{antecedent: %Address{type: "judgment_observation"}}, &1)
             )
    end
  end

  describe "a person-grade fact" do
    test "is attributed to a person, with no banding to resolve" do
      s = scenario()
      e = explain(%{s | fact: %{s.fact | admission_grade: :person}, links: %{}})

      assert relations(e) == [:was_attributed_to]
      assert e.gaps == []
      assert hd(e.steps).agent_label == "a person"
    end
  end

  test "no value, probability or atom text reaches the explanation" do
    s = scenario()
    s = put_in(s, [:links, :observations, Access.at(0), :probabilities], %{"p_true" => "0.91"})
    s = put_in(s, [:fact, :value], "sensitive-value")

    refute inspect(explain(s)) =~ "0.91"
    refute inspect(explain(s)) =~ "sensitive-value"
  end

  test "a missing :base is refused" do
    s = scenario()
    assert_raise KeyError, fn -> Explain.fact(s.fact, s.links, []) end
  end
end
