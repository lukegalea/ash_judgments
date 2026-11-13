# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsReplayTest do
  @moduledoc """
  `AshJudgments.Facts.Replay` on the temporal test host: the decisions read back
  out of the event log take effect at each write's `as_of`, and replaying them
  into an empty table rebuilds the same periods.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Facts.Replay
  alias AshJudgments.Test.EventLog
  alias AshJudgments.Test.Fact

  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"

  @t1 ~U[2025-01-10 00:00:00Z]
  @t2 ~U[2025-06-01 00:00:00Z]
  @t3 ~U[2025-09-01 00:00:00Z]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")
    AshJudgments.TestRepo.query!("DELETE FROM test_event_log")

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :facts, Fact)
    on_exit(fn -> Application.delete_env(:ash_judgments, :facts) end)
    :ok
  end

  # Recorded in this order, all of them now. "later" is recorded first and takes
  # effect last; "earlier" is admitted, revised and truncated, each back-dated.
  defp record_history do
    {:ok, :materialised} = materialise("later", effective_at: @t3)
    {:ok, :materialised} = materialise("earlier", effective_at: @t1)

    {:ok, :materialised} =
      materialise("earlier", value: "routine", holds: false, effective_at: @t2)

    {:ok, :superseded} = materialise("earlier", result: :omitted, effective_at: @t3)
  end

  test "decisions take effect at the write's as_of, in that order" do
    record_history()

    {:ok, decisions} = Replay.decisions_from_event_log(EventLog)

    assert summary(decisions) == [
             {"earlier", :admitted, "urgent", usec(@t1)},
             {"earlier", :admitted, "routine", usec(@t2)},
             {"later", :admitted, "urgent", usec(@t3)},
             {"earlier", :omitted, nil, usec(@t3)}
           ]

    # A revision's event carries only the revised fields; the rest come from the
    # record's payload.
    revised = Enum.at(decisions, 1)
    assert revised.predicate == @predicate
    assert revised.holds == false
    assert revised.admission_grade == :grant
  end

  test "replaying the decisions into an empty table rebuilds the same periods" do
    record_history()
    before = periods()
    assert length(before) == 3

    {:ok, decisions} = Replay.decisions_from_event_log(EventLog)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")

    assert {:ok, %{replayed: 4, materialised: 3, superseded: 1}} = Replay.replay(decisions)
    assert periods() == before
  end

  test "replay refuses a facts resource that is not temporal" do
    assert_raise ArgumentError, ~r/temporal facts resource/, fn ->
      Replay.replay([], resource: AshJudgments.Test.LegacyFact)
    end
  end

  defp materialise(subject_id, overrides) do
    [
      result: :admitted,
      subject: subject(subject_id),
      predicate: @predicate,
      value: "urgent",
      holds: true,
      grade: :grant,
      admission_id: Ash.UUID.generate()
    ]
    |> Keyword.merge(overrides)
    |> Materialiser.materialise()
  end

  defp subject(id), do: %{"type" => "AshJudgments.Test.Appointment", "id" => "replay-#{id}"}

  defp summary(decisions) do
    Enum.map(decisions, fn decision ->
      {String.replace_prefix(decision.subject["id"], "replay-", ""), decision.result,
       decision[:value], usec(decision.effective_at)}
    end)
  end

  defp usec(datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp periods do
    AshJudgments.TestRepo.query!("""
    select subject_id, value::text, holds::text, lower(valid_at)::text,
           coalesce(upper(valid_at)::text, 'unbounded')
    from test_facts
    order by subject_id, lower(valid_at)
    """).rows
  end
end
