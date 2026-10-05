# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.ExplorationTest do
  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Exploration
  alias AshJudgments.Exploration.Ordering
  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Registry
  alias AshJudgments.Registry.Canonical

  @ledger AshJudgments.Test.Judgment
  @proposals AshJudgments.Test.QuestionProposal
  @triage "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"
  @exploratory "judgment:v0:AshJudgments.Test.Note#judgments/exploratory"

  # The ad-hoc question every exploratory run in this suite explores with.
  defp question do
    %{
      type: AshAi.Evaluate.Noul,
      instructions: "Does this note describe an unsafe transfer?",
      state_shape: %{"text" => "string"}
    }
  end

  describe "the exploratory namespace ([L]1)" do
    test "the reserved id is the declared-question grammar with the exploratory slot" do
      assert Exploration.question_id(AshJudgments.Test.Note) == @exploratory
      assert String.starts_with?(@exploratory, "judgment:v0:AshJudgments.Test.Note#judgments/")
    end

    test "exploratory? ties null-family eligibility to exactly the namespace" do
      assert Exploration.exploratory?(@exploratory)
      assert Exploration.exploratory?(@triage) == false
      assert Exploration.exploratory?(nil) == false
      # The suffix, not a substring: a declared question whose id merely
      # CONTAINS the fragment is not exploratory.
      assert Exploration.exploratory?(@triage <> "/exploratory_other") == false
    end

    test "the identity hash is the content address: the hash, not the slot, is the identity" do
      q1 = %{type: AshAi.Evaluate.Noul, instructions: "Does this note commit a follow-up?"}
      q2 = %{type: AshAi.Evaluate.Noul, instructions: "Does this note commit a follow-up?"}
      q3 = %{type: AshAi.Evaluate.Noul, instructions: "Does this note commit a FOLLOW-UP?"}

      assert Exploration.identity_hash(q1) == Exploration.identity_hash(q2)
      refute Exploration.identity_hash(q1) == Exploration.identity_hash(q3)

      # Same slot, different content — distinct identities under one id.
      assert length(Exploration.identity(q1).options) == 2
    end

    test "the identity object is the §3.2 shape at version 1" do
      identity =
        Exploration.identity(%{
          type: AshAi.Evaluate.Noul,
          instructions: "Question?",
          state_shape: %{"text" => "string"}
        })

      assert identity.version == 1
      assert identity.answer_type == AshAi.Evaluate.Noul
      assert identity.options == [true, false]
      assert identity.state_contract == Canonical.state_contract(%{"text" => "string"})

      assert identity_hash = Canonical.question_hash(identity)
      assert String.starts_with?(identity_hash, "sha256:")
    end

    test "bounds and threshold are the recorded defaults ([L]4)" do
      assert Exploration.default_subjects() == 100
      assert Exploration.hard_cap() == 500
      assert Exploration.threshold() == 3
    end
  end

  describe "ordering validation (§1.3)" do
    test "a declared question with one of its derived options resolves" do
      assert {:ok, %Ordering{} = spec} =
               Ordering.resolve(AshJudgments.Test.Appointment,
                 question_id: @triage,
                 selector: :urgent
               )

      assert spec.source == :observation
      assert spec.direction == :asc
      assert spec.selector == :urgent
    end

    test "an undeclared question_id is a validation error, never a silent skip" do
      assert {:error, %Exploration.UnknownQuestion{}} =
               Ordering.resolve(AshJudgments.Test.Appointment,
                 question_id: "judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up",
                 selector: true
               )
    end

    test "an exploratory question never orders — it decorates" do
      assert {:error, %Exploration.UnknownQuestion{}} =
               Ordering.resolve(AshJudgments.Test.Note, question_id: @exploratory, selector: true)
    end

    test "a selector outside the question's derived options is refused" do
      assert {:error, %Exploration.UnknownSelector{}} =
               Ordering.resolve(AshJudgments.Test.Appointment,
                 question_id: @triage,
                 selector: :telepathy
               )
    end

    test "no score-only orderings: a missing selector, nil, or the score itself is refused" do
      # No selector at all — the refusal names the score-only rule.
      assert {:error, %Exploration.ScoreOnlyOrdering{}} =
               Ordering.resolve(AshJudgments.Test.Appointment, question_id: @triage)

      # An explicit nil is the same refusal, not an absent-key ambiguity.
      assert {:error, %Exploration.ScoreOnlyOrdering{}} =
               Ordering.resolve(AshJudgments.Test.Appointment,
                 question_id: @triage,
                 selector: nil
               )

      # The shorthands that name the score itself.
      for shorthand <- ["score", "magnitude", "position", :score] do
        assert {:error, %Exploration.ScoreOnlyOrdering{selector: ^shorthand}} =
                 Ordering.resolve(AshJudgments.Test.Appointment,
                   question_id: @triage,
                   selector: shorthand
                 )
      end
    end

    test "a Noul's selector can be false — an absent selector is the refusal, not a falsy one" do
      assert {:ok, %Ordering{selector: false}} =
               Ordering.resolve(AshJudgments.Test.Note,
                 question_id: "judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up",
                 selector: false
               )
    end

    test "a Score question orders by a NAMED level, never by the score" do
      assert {:ok, %Ordering{}} =
               Ordering.resolve(AshJudgments.Test.Appointment,
                 question_id: @triage,
                 selector: "routine",
                 direction: :desc
               )
    end
  end

  describe "the ordering read path (§1.3–§1.4)" do
    setup :configure_stack

    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

      for table <-
            ~w(test_judgments test_human_verdicts test_facts test_event_log test_question_proposals) do
        AshJudgments.TestRepo.query!("DELETE FROM " <> table)
      end

      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)

      Application.put_env(:ash_judgments, :ledger, @ledger)
      on_exit(fn -> Application.delete_env(:ash_judgments, :ledger) end)
      :ok
    end

    test "the [L]5 partial index exists over the read the ordering rides" do
      %{rows: rows} =
        AshJudgments.TestRepo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'test_judgments_latest_live_answers_index'"
        )

      [definition] = List.flatten(rows)
      assert definition =~ "test_judgments"
      assert definition =~ "question_id"
      assert definition =~ "recorded_at DESC"
      assert definition =~ "WHERE"
      assert definition =~ "mode" and definition =~ "'live'"
    end

    test "latest live answered observation per (question, subject) — shadow and older rows lose" do
      subject_a = %{subject_type: "appointment", subject_id: "a1"}
      subject_b = %{subject_type: "appointment", subject_id: "a2"}

      record_observation(subject_a, @triage, "routine")
      record_observation(subject_a, @triage, "emergency")
      # A shadow row never orders (calibration surface, not person-facing).
      record_observation(subject_b, @triage, "emergency", mode: :shadow)
      record_observation(subject_b, @triage, "routine")

      latest = Ordering.latest_answers(@ledger, @triage)

      assert map_size(latest) == 2
      assert latest[{"appointment", "a1"}].value == "emergency"
      assert latest[{"appointment", "a2"}].value == "routine"
    end

    test "ordering is decoration, never membership: nulls last carrying no meaning, rows kept" do
      record_observation(%{subject_type: "appointment", subject_id: "a1"}, @triage, "emergency")
      # A non-matching answer is a scored row, not a null.
      record_observation(%{subject_type: "appointment", subject_id: "a2"}, @triage, "routine")

      # A shadow row must not decorate either — the subject reads as unassessed.
      record_observation(%{subject_type: "appointment", subject_id: "a3"}, @triage, "emergency",
        mode: :shadow
      )

      rows = [
        %{subject_type: "appointment", subject_id: "a1"},
        %{subject_type: "appointment", subject_id: "a2"},
        %{subject_type: "appointment", subject_id: "a3"}
      ]

      spec =
        Ordering.resolve!(AshJudgments.Test.Appointment,
          question_id: @triage,
          selector: :emergency
        )

      ordered = Ordering.sort(rows, Ordering.latest_answers(@ledger, @triage), spec)

      # A permutation of the input: no row hidden, no row added (§1.2).
      # Selector-matching first, then the scored non-match, nulls last.
      assert Enum.map(ordered, & &1.subject_id) == ["a1", "a2", "a3"]

      # Direction desc: the selector's rows move behind the scored
      # non-match; nulls still last of all.
      ordered_desc =
        Ordering.sort(rows, Ordering.latest_answers(@ledger, @triage), %{spec | direction: :desc})

      assert Enum.map(ordered_desc, & &1.subject_id) == ["a2", "a1", "a3"]
    end

    test "a Noul selector matches the collapsed two-way distribution, the chip labels the row" do
      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

      AshJudgments.Test.Note
      |> Ash.ActionInput.for_action(:judge_notes_follow_up, %{
        "input" => %{"text" => "The resident will need a follow-up appointment next week."}
      })
      |> Ash.run_action!(context: %{judgments: %{req_llm: AshJudgments.Test.FakeReqLLM}})

      question_id = "judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up"

      rows = [%{subject_type: nil, subject_id: nil}]
      spec = Ordering.resolve!(AshJudgments.Test.Note, question_id: question_id, selector: true)
      records = Ordering.latest_answers(@ledger, question_id)

      assert Ordering.sort(rows, records, spec) == rows

      [record] = Map.values(records)
      chip = Ordering.chip(record)

      assert chip.profile == "test_local"
      assert chip.p == "0.9"
      assert is_integer(chip.latency_us)
      # The wire-reported model is absent on the fake transport; the chip
      # carries provenance, never an invention.
      assert chip.model in [nil, record.model_version]
    end
  end

  describe "the exploratory run (§4.1–§4.3)" do
    setup :configure_stack

    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

      for table <-
            ~w(test_judgments test_human_verdicts test_facts test_event_log test_question_proposals) do
        AshJudgments.TestRepo.query!("DELETE FROM " <> table)
      end

      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)

      Application.put_env(:ash_judgments, :ledger, @ledger)
      on_exit(fn -> Application.delete_env(:ash_judgments, :ledger) end)

      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})
      :ok
    end

    defp subjects(n) do
      for i <- 1..n do
        %{subject_type: "note", subject_id: "n#{i}", state: %{"text" => "synthetic note #{i}"}}
      end
    end

    test "records ordinary observations: exploratory id, family NULL, live mode, identity hash" do
      assert {:ok, results} =
               Exploration.Run.run(AshJudgments.Test.Note, question(), subjects(3),
                 profile: :test_local,
                 actor: "person:1",
                 req_llm: AshJudgments.Test.FakeReqLLM
               )

      assert length(results) == 3
      assert Enum.all?(results, &match?(%{answer: %AshAi.Evaluate.Noul{probability: 0.9}}, &1))
      assert Enum.all?(results, &(&1.cache_hit? == false))

      rows = Ash.read!(@ledger)
      assert length(rows) == 3
      correlation_ids = rows |> Enum.map(& &1.correlation_id) |> Enum.uniq()

      # One audited invocation: every row of the run shares the correlation id.
      assert length(correlation_ids) == 1

      for row <- rows do
        assert row.question_id == @exploratory
        assert row.family == nil
        assert row.mode == :live
        assert row.question_version == 1
        assert row.question_hash == Exploration.identity_hash(question())
        assert row.wire_question_hash
        assert row.answer_kind == :noul
        assert row.value == nil
      end
    end

    test "bounds: over the cap is refused, never silently truncated ([L]4)" do
      assert {:error, %Exploration.BoundExceeded{given: 501, cap: 500}} =
               Exploration.Run.run(AshJudgments.Test.Note, question(), subjects(501),
                 profile: :test_local,
                 req_llm: AshJudgments.Test.FakeReqLLM
               )

      assert {:error, %Exploration.BoundExceeded{}} =
               Exploration.Run.run(AshJudgments.Test.Note, question(), subjects(2),
                 profile: :test_local,
                 limit: 501,
                 req_llm: AshJudgments.Test.FakeReqLLM
               )

      # The default bound slices a bounded list to the caller's card default.
      assert {:ok, results} =
               Exploration.Run.run(AshJudgments.Test.Note, question(), subjects(150),
                 profile: :test_local,
                 limit: 2,
                 req_llm: AshJudgments.Test.FakeReqLLM
               )

      assert length(results) == 2
    end

    test "a cache hit writes no observation and returns the existing row (§4.4/§6.3)" do
      opts = [
        profile: :test_local,
        ttl: 3600,
        correlation_id: Ash.UUID.generate(),
        req_llm: AshJudgments.Test.FakeReqLLM
      ]

      assert {:ok, [first, _]} =
               Exploration.Run.run(AshJudgments.Test.Note, question(), subjects(2), opts)

      assert {:ok, [second, _]} =
               Exploration.Run.run(
                 AshJudgments.Test.Note,
                 question(),
                 subjects(2),
                 Keyword.put(opts, :correlation_id, Ash.UUID.generate())
               )

      assert second.cache_hit?
      assert second.observation_id == first.observation_id
      assert length(Ash.read!(@ledger)) == 2
    end

    test "the family invariant: exploratory rows refuse a family; declared rows refuse nil" do
      # Forged: an exploratory id WITH a family is refused.
      assert {:error, _} =
               @ledger
               |> Ash.Changeset.for_create(:record, %{
                 question_id: @exploratory,
                 question_hash: "sha256:" <> String.duplicate("0", 64),
                 question_version: 1,
                 family: "clinic_notes",
                 state_digest: "sha256:" <> String.duplicate("1", 64),
                 answer_kind: :noul,
                 model_spec_requested: "test-model",
                 profile: "test_local",
                 cache_key: "forged",
                 mode: :live
               })
               |> Ash.create()

      # Forged the other way: a declared question id with family nil.
      assert {:error, _} =
               @ledger
               |> Ash.Changeset.for_create(:record, %{
                 question_id: @triage,
                 question_hash: "sha256:" <> String.duplicate("0", 64),
                 question_version: 1,
                 family: nil,
                 state_digest: "sha256:" <> String.duplicate("1", 64),
                 answer_kind: :choice,
                 model_spec_requested: "test-model",
                 profile: "test_local",
                 cache_key: "forged-2",
                 mode: :live
               })
               |> Ash.create()
    end

    test "never banded: the banding input builder refuses the namespace (§4.2)" do
      assert {:ok, [result]} =
               Exploration.Run.run(AshJudgments.Test.Note, question(), subjects(1),
                 profile: :test_local,
                 req_llm: AshJudgments.Test.FakeReqLLM
               )

      answer_map = %{
        question: %{name: :exploratory, question_id: @exploratory},
        answer: result.answer
      }

      assert_raise ArgumentError, ~r/never banded/, fn ->
        Dmn.inputs([answer_map], family: "clinic_notes")
      end
    end

    test "never admitted, never fact-fed: the materialiser refuses the namespace, any grade" do
      for grade <- [:grant, :person] do
        assert {:error, %Exploration.ExploratoryRefused{surface: "the fact materialiser"}} =
                 Materialiser.materialise(%{
                   result: :admitted,
                   subject: %{"note" => "n1"},
                   predicate: @exploratory,
                   value: %{"commitment" => true},
                   holds: true,
                   grade: grade
                 })
      end

      # Nothing leaked into the facts table.
      assert AshJudgments.Test.Fact |> Ash.read!() == []
    end
  end

  describe "recurrence detection (§4.4)" do
    setup :configure_stack

    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

      for table <-
            ~w(test_judgments test_human_verdicts test_facts test_event_log test_question_proposals) do
        AshJudgments.TestRepo.query!("DELETE FROM " <> table)
      end

      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)

      Application.put_env(:ash_judgments, :ledger, @ledger)
      on_exit(fn -> Application.delete_env(:ash_judgments, :ledger) end)

      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})
      :ok
    end

    defp run_n(subjects, actor, opts \\ []) do
      Exploration.Run.run(
        AshJudgments.Test.Note,
        question(),
        subjects,
        [profile: :test_local, actor: actor, req_llm: AshJudgments.Test.FakeReqLLM] ++ opts
      )
    end

    defp subjects_in(range, tag) do
      for i <- range do
        %{
          subject_type: "note",
          subject_id: "#{tag}#{i}",
          state: %{"text" => "synthetic #{tag}#{i}"}
        }
      end
    end

    test "counts DISTINCT invocations, not rows: one run over N subjects is one invocation" do
      assert {:ok, _} = run_n(subjects_in(1..3, "a"), "person:1")

      [group] = Exploration.Recurrence.detect(@ledger)

      assert group.invocation_count == 1
      assert group.actor_count == 1
      assert group.observation_count == 3
      assert group.crossed? == false
    end

    test "the counts accumulate per wire hash across invocations and actors" do
      assert {:ok, _} = run_n(subjects_in(1..2, "a"), "person:1")
      assert {:ok, _} = run_n(subjects_in(3..4, "b"), "person:2")
      assert {:ok, _} = run_n(subjects_in(5..6, "c"), "person:1")

      [group] = Exploration.Recurrence.detect(@ledger)

      assert group.invocation_count == 3
      assert group.actor_count == 2
      assert group.observation_count == 6
      assert group.crossed? == true
    end

    test "a cache hit writes no observation and does NOT count (§4.4)" do
      assert {:ok, _} = run_n(subjects_in(1..2, "a"), "person:1")
      assert {:ok, _} = run_n(subjects_in(1..2, "a"), "person:1", ttl: 3600)

      [group] = Exploration.Recurrence.detect(@ledger)

      assert group.invocation_count == 1
      assert group.actor_count == 1
    end

    test "the aggregates are envelope-only: counts and hashes, never ids or values" do
      assert {:ok, _} = run_n(subjects_in(1..3, "a"), "person:secret-actor")

      [group] = Exploration.Recurrence.detect(@ledger)

      assert MapSet.new(Map.keys(group)) ==
               MapSet.new([
                 :wire_question_hash,
                 :invocation_count,
                 :actor_count,
                 :observation_count,
                 :answer_distribution,
                 :crossed?
               ])

      # No actor id anywhere in the artefact...
      refute inspect(group) =~ "secret-actor"

      # ...no subject id (the quoted token, not a hex-hash substring)...
      refute inspect(group) =~ ~r/"a[123]"/

      # ...and the distribution names only the value vocabulary with counts.
      assert group.answer_distribution == %{"true" => 3}
    end

    test "a different wire hash is a different question; shadow rows are not invocations" do
      assert {:ok, _} = run_n(subjects_in(1..1, "a"), "person:1")

      other = %{question() | instructions: "Different wording, different question"}

      assert {:ok, _} =
               Exploration.Run.run(AshJudgments.Test.Note, other, subjects_in(2..2, "b"),
                 profile: :test_local,
                 actor: "person:1",
                 req_llm: AshJudgments.Test.FakeReqLLM
               )

      groups = Exploration.Recurrence.detect(@ledger)
      assert length(groups) == 2
      assert Enum.all?(groups, &(&1.invocation_count == 1))
    end
  end

  describe "the promotion path (§4.5)" do
    setup :configure_stack

    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

      for table <-
            ~w(test_judgments test_human_verdicts test_facts test_event_log test_question_proposals) do
        AshJudgments.TestRepo.query!("DELETE FROM " <> table)
      end

      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)

      Application.put_env(:ash_judgments, :ledger, @ledger)
      on_exit(fn -> Application.delete_env(:ash_judgments, :ledger) end)

      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})
      :ok
    end

    defp run_once(tag) do
      Exploration.Run.run(
        AshJudgments.Test.Note,
        question(),
        [
          %{subject_type: "note", subject_id: "#{tag}1", state: %{"text" => "synthetic"}},
          %{subject_type: "note", subject_id: "#{tag}2", state: %{"text" => "synthetic other"}}
        ],
        profile: :test_local,
        actor: "person:1",
        req_llm: AshJudgments.Test.FakeReqLLM
      )
    end

    test "crossing K mints ONE proposal per wire hash; the person is the proposer ([L]3)" do
      assert {:ok, _} = run_once("a")
      assert {:ok, _} = run_once("b")
      assert {:ok, _} = run_once("c")

      [%{wire_question_hash: wire_question_hash} | _] =
        groups = Exploration.Recurrence.detect(@ledger)

      assert hd(groups).crossed?

      assert {:ok, proposal} =
               Exploration.Recurrence.promote(@ledger, @proposals, wire_question_hash, question(),
                 actor: "person:7",
                 subject_resource: AshJudgments.Test.Note
               )

      assert proposal.question_id == @exploratory
      assert proposal.question_hash == Exploration.identity_hash(question())
      assert proposal.invocation_count == 3
      assert proposal.actor_count == 1
      assert proposal.observation_count == 6
      assert proposal.answer_distribution == %{"true" => 6}
      assert Enum.sort(proposal.subject_sample) == ["a1", "a2", "b1", "b2", "c1", "c2"]
      assert proposal.proposer == %{"kind" => "person", "id" => "person:7"}

      assert proposal.metadata["detector"] == "AshJudgments.Exploration.Recurrence"
      assert proposal.metadata["detector_version"] == "1"
      assert proposal.metadata["threshold_k"] == 3
      assert String.starts_with?(proposal.record_hash, "sha256:")

      # One proposal per wire hash — the detector proposes once.
      assert {:error, %Exploration.AlreadyProposed{}} =
               Exploration.Recurrence.promote(@ledger, @proposals, wire_question_hash, question(),
                 actor: "person:7",
                 subject_resource: AshJudgments.Test.Note
               )
    end

    test "one explicit person promote mints below K — both paths are the person's" do
      assert {:ok, _} = run_once("a")

      [%{wire_question_hash: wire_question_hash, crossed?: false}] =
        Exploration.Recurrence.detect(@ledger)

      assert {:ok, proposal} =
               Exploration.Recurrence.promote(@ledger, @proposals, wire_question_hash, question(),
                 actor: "person:9",
                 subject_resource: AshJudgments.Test.Note
               )

      assert proposal.invocation_count == 1
      assert proposal.metadata["threshold_k"] == 3
    end

    test "the detector only proposes: detect never mints, nothing auto-declares" do
      declared_before = Registry.questions(AshJudgments.Test.Note)
      actions_before = Ash.Resource.Info.actions(AshJudgments.Test.Note)

      assert {:ok, _} = run_once("a")
      assert {:ok, _} = run_once("b")
      assert {:ok, _} = run_once("c")

      # Detection is a pure read: no proposal row, no registry change.
      assert length(Exploration.Recurrence.detect(@ledger)) == 1
      assert Ash.read!(@proposals) == []

      # The person mints — and the mint writes an inert record: no
      # declared question appears, no judge action appears.
      [%{wire_question_hash: wire_question_hash}] = Exploration.Recurrence.detect(@ledger)

      assert {:ok, _proposal} =
               Exploration.Recurrence.promote(@ledger, @proposals, wire_question_hash, question(),
                 actor: "person:7",
                 subject_resource: AshJudgments.Test.Note
               )

      assert Registry.questions(AshJudgments.Test.Note) == declared_before
      assert length(Ash.Resource.Info.actions(AshJudgments.Test.Note)) == length(actions_before)

      refute Enum.any?(
               Ash.Resource.Info.actions(AshJudgments.Test.Note),
               &(&1.name in [:judge_exploratory, :exploratory])
             )

      # The lock is untouched: the 3-question registry is exactly as frozen.
      assert Enum.map(Registry.questions(AshJudgments.Test.Appointment), & &1.question_id)
             |> length() == 2
    end
  end

  ## Helpers

  # Inserts an observation for the ordering read-path tests directly: the
  # test drives the envelope fields (the banding/admission read path sees
  # ordinary rows), with recorded_at separated deterministically.
  defp record_observation(subject, question_id, value, opts \\ []) do
    {:ok, row} =
      @ledger
      |> Ash.Changeset.for_create(:record, %{
        id: Ash.UUID.generate(),
        question_id: question_id,
        question_hash: "sha256:" <> String.duplicate("0", 64),
        question_version: 1,
        family: "clinic_triage",
        subject_type: subject.subject_type,
        subject_id: subject.subject_id,
        state_digest: "sha256:" <> String.duplicate("3", 64),
        answer_kind: :choice,
        value: value,
        probabilities: %{value => "0.9"},
        model_spec_requested: "test-model",
        profile: "test_local",
        mode: opts[:mode] || :live
      })
      |> Ash.create()

    if at = opts[:recorded_at] do
      AshJudgments.TestRepo.query!(
        "UPDATE test_judgments SET recorded_at = $1 WHERE id = $2",
        [at, row.id]
      )
    end

    row
  end
end
