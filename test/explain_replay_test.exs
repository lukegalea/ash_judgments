# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.ExplainReplayTest do
  @moduledoc """
  A fact rebuilt by `AshJudgments.Facts.Replay` is explained from what the replay carried: a recorded `admission_id`
  keeps the chain, and a decision that carried none reads `:not_recorded`, because a replay never re-evaluates.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Explain
  alias AshJudgments.Facts.{Materialiser, Replay}
  alias AshJudgments.Test.{EventLog, Fact}
  alias AshProvenance.Gap

  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"
  @base "https://example.test/aj"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")
    AshJudgments.TestRepo.query!("DELETE FROM test_event_log")

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :facts, Fact)
    on_exit(fn -> Application.delete_env(:ash_judgments, :facts) end)
    :ok
  end

  defp admit(subject_id, admission_id) do
    {:ok, :materialised} =
      Materialiser.materialise(
        result: :admitted,
        subject: %{"type" => "AshJudgments.Test.Appointment", "id" => "explain-#{subject_id}"},
        predicate: @predicate,
        value: "urgent",
        holds: true,
        grade: :grant,
        admission_id: admission_id
      )
  end

  defp replayed_facts do
    {:ok, decisions} = Replay.decisions_from_event_log(EventLog)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")
    {:ok, %{materialised: 2}} = Replay.replay(decisions)

    Fact |> Ash.read!() |> Map.new(&{&1.subject_id, &1})
  end

  test "a replayed fact with no recorded admission reads :not_recorded; one that kept it keeps its chain" do
    banding_id = Ash.UUID.generate()
    admit("linked", banding_id)
    admit("silent", nil)

    facts = replayed_facts()

    {:ok, silent} = Explain.fact(facts["explain-silent"], %{}, base: @base)
    assert silent.steps == []
    assert [%Gap{kind: :not_recorded}] = silent.gaps

    banding = %{
      id: banding_id,
      band: :admit,
      matched_rule_ids: ["r1"],
      observation_ids: [],
      decision_evaluation_id: nil
    }

    {:ok, linked} = Explain.fact(facts["explain-linked"], %{banding: banding}, base: @base)

    assert [%{relation: :was_generated_by, activity: activity} | _] = linked.steps
    assert activity == "banding:" <> banding_id
  end
end
