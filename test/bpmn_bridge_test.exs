# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.BpmnBridgeTest do
  @moduledoc """
  The BPMN bridge integration suite (AST-94): the standing-evaluation
  fixture runs through the ash_bpmn interpreter on the test host, the
  judged-signals callable promotes flat scalars onto the token, and the
  gateway routes on them. ash_bpmn is a DEV/TEST-ONLY optional dep; the
  callable-generation and shape tests run regardless (they never touch
  the engine), and this file's integration tests skip when the dep is
  absent.
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  require Ash.Query

  @moduletag :bpmn_integration

  alias AshJudgments.Bridge.Bpmn
  alias AshJudgments.Registry.Info

  @subject %{"type" => "AshJudgments.Test.Note", "id" => "note-bpmn-1"}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_facts test_event_log
                     bpmn_definitions bpmn_instances bpmn_tokens
                     bpmn_human_tasks bpmn_task_candidates
                     bpmn_process_events) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)

    put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

    Application.put_env(:ash_judgments, :test_judgments_ctx, %{
      req_llm: AshJudgments.Test.FakeReqLLM
    })

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :ledger)
      Application.delete_env(:ash_judgments, :region)
      Application.delete_env(:ash_judgments, :test_judgments_ctx)
    end)

    :ok
  end

  @fixture Path.join(:code.priv_dir(:ash_judgments), "bpmn/standing_evaluation.bpmn")

  defp observation_count do
    AshJudgments.Test.Judgment |> Ash.read!() |> length()
  end

  describe "the no-runtime-edge discipline (t-core-bridge-placement §0)" do
    test "lib/ never references the engine outside the availability registry atom" do
      # The DAG forbids a runtime edge in either direction: this package's
      # lib/ must not import or call ash_bpmn. The ONLY allowed mention is
      # the module atom in the availability registry (the optional-dep
      # seam, same as :ash_rules and :ash_decisions there).
      lib_sources = Path.wildcard("lib/**/*.ex")

      assert lib_sources != []

      for path <- lib_sources do
        source = File.read!(path)

        offending =
          source
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _i} ->
            String.contains?(line, "module: AshBpmn,") or
              String.contains?(line, "SPDX") or String.contains?(line, "License")
          end)
          |> Enum.filter(fn {line, _i} -> String.contains?(line, "AshBpmn") end)

        assert offending == [],
               "runtime edge to ash_bpmn in #{path}:
" <>
                 Enum.map_join(offending, "\n", fn {line, i} ->
                   "  #{i}: #{String.trim(line)}"
                 end)
      end
    end
  end

  describe "the generated signals actions (no engine needed)" do
    test "bpmn_callable? generates the signals action on the host resource" do
      action = Ash.Resource.Info.action(AshJudgments.Test.Note, :judge_notes_follow_up_signals)

      assert action != nil
      assert action.type == :action
      assert action.returns in [:map, Ash.Type.Map]
    end

    test "questions without bpmn_callable? generate no signals action" do
      refute Ash.Resource.Info.action(
               AshJudgments.Test.Appointment,
               :judge_triage_urgency_signals
             )
    end

    test "the signals map is STRING-KEYED and SCALAR-VALUED — no structs leak (the promotion discipline)" do
      answer = struct(AshAi.Evaluate.Noul, probability: 0.94)
      question = Info.questions(AshJudgments.Test.Note) |> List.first()

      signals = Bpmn.signal_map("notes_follow_up", question, answer, "obs-1")

      for {k, v} <- signals do
        assert is_binary(k), "key #{inspect(k)} is not a string"

        assert is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
               "value #{inspect(v)} for #{inspect(k)} is not a scalar"
      end

      assert signals["notes_follow_up__judgment_id"] == "obs-1"
      assert signals["notes_follow_up__p"] == "0.94"
    end

    test "the signals callable runs end-to-end through the judge and records" do
      {:ok, signals} =
        AshJudgments.Test.Note
        |> Ash.ActionInput.for_action(:judge_notes_follow_up_signals, %{
          "input" => %{"text" => "synthetic bpmn text"}
        })
        |> Ash.run_action(
          context: %{judgments: %{req_llm: AshJudgments.Test.FakeReqLLM, mode: :live}}
        )

      # Scalar-only shape — the promotion discipline (no structs leak).
      for {k, v} <- signals do
        assert is_binary(k), "key #{inspect(k)} is not a string"

        assert is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
               "value #{inspect(v)} for #{inspect(k)} is not a scalar"
      end

      # The judgment id is the token's join back to the ledger row.
      assert is_binary(signals["notes_follow_up__judgment_id"])

      # The observation landed in the ledger.
      assert observation_count() == 1
    end
  end

  describe "the standing-evaluation fixture through the interpreter" do
    @describetag :integration

    test "the judged signals promote onto the token and the admit lane completes" do
      definition = create_published_definition!()

      note =
        AshJudgments.Test.Note
        |> Ash.Changeset.for_create(:create, %{body: "synthetic bpmn note"})
        |> Ash.create!()

      {:ok, instance} =
        AshBpmn.start_instance(AshJudgments.Test.Bpmn.Domain,
          process: "standing_evaluation",
          subject: note
        )

      # Judged (p = 0.9) → banded admit → the admitted end, all inline.
      assert instance.status == :completed
      assert instance.outcome == "admitted"

      # The judged observation landed in the ledger; the promoted
      # judgment id is the join back to the full row (deliverable: the
      # judgment-id join).
      [judgment] = Ash.read!(AshJudgments.Test.Judgment)
      assert judgment.question_id =~ "notes_follow_up"

      [event] = process_events(instance.id, :action_invoked, "JudgeSignals")
      assert event.data["action"] == "AshJudgments.Test.Bpmn.Domain.judge_note_signals"
      assert event.data["promoted"]["notes_follow_up__p"] == "0.9"
      assert event.data["promoted"]["notes_follow_up__judgment_id"] == judgment.id

      _ = definition
    end

    test "the review lane creates a task that completes the instance" do
      _definition = create_published_definition!()

      note =
        AshJudgments.Test.Note
        |> Ash.Changeset.for_create(:create, %{body: "synthetic bpmn note"})
        |> Ash.create!()

      # A middling probability bands to review: the task lane.
      Application.put_env(:ash_judgments, :test_probability, 0.7)

      {:ok, instance} =
        AshBpmn.start_instance(AshJudgments.Test.Bpmn.Domain,
          process: "standing_evaluation",
          subject: note
        )

      assert instance.status == :running

      assert [%{status: :open} = task] = open_tasks(instance.id)

      # The reviewer principal from the resolver seam completes the task —
      # the actor the engine records on the task decision.
      {:ok, _completed} =
        AshBpmn.complete_task(task,
          outcome: :confirm,
          actor: %{id: AshJudgments.Test.BpmnResolver.reviewer()}
        )

      instance = Ash.reload!(instance)
      assert instance.status == :completed
      assert instance.outcome == "reviewed"
    after
      Application.delete_env(:ash_judgments, :test_probability)
    end

    # The definition's key is what `start_instance` resolves the process
    # by (latest published for the key) — the XML's process id is the
    # diagram's own identity, the key is the host's lookup.
    defp create_published_definition! do
      xml = File.read!(@fixture)

      defn =
        AshJudgments.Test.Bpmn.Definition
        |> Ash.Changeset.for_create(:create, %{
          key: "standing_evaluation",
          name: "Standing evaluation",
          xml: xml
        })
        |> Ash.create!()

      if defn.graph do
        AshJudgments.TestRepo.query!(
          "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
        )

        AshJudgments.Test.Bpmn.Definition.by_key_version!(defn.key, defn.version)
      else
        raise "Definition failed to compile: #{inspect(defn.errors)}"
      end
    end

    defp process_events(instance_id, kind, node_id) do
      AshJudgments.Test.Bpmn.ProcessEvent
      |> Ash.Query.filter(instance_id == ^instance_id and kind == ^kind and node_id == ^node_id)
      |> Ash.read!(authorize?: false)
    end

    defp open_tasks(instance_id) do
      AshJudgments.Test.Bpmn.HumanTask
      |> Ash.Query.filter(instance_id == ^instance_id and status == ^"open")
      |> Ash.read!(authorize?: false)
    end
  end
end
