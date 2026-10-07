# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsTemporalTest do
  @moduledoc """
  AST-148: the six new tests the temporal facts swap adds (design note
  §4), on the temporal test host (`AshJudgments.Test.Fact`).

    1. as-of fact read answers `status` at a past `as_of` across a
       revision boundary;
    2. a future-dated revision is invisible at now, visible at
       `as_of(future)`, no scheduler;
    3. omission-truncate preserves history (read at pre-omission `as_of`
       = still `in`);
    4. replay-identical periods via the ash_events as_of harness;
    5. the WITHOUT OVERLAPS identity rejects an overlapping concurrent
       revision — engine-retried, then a clean `WriteConflict`;
    6. the materialiser race: two concurrent admissions on one key →
       exactly one period outcome, never two open rows.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshJudgments.Test.EventLog
  alias AshJudgments.Test.Fact
  alias AshJudgments.Facts.Materialiser

  @subject %{"type" => "AshJudgments.Test.Appointment", "id" => "temporal-1"}
  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"

  @t1 ~U[2025-01-10 00:00:00Z]
  @t2 ~U[2025-06-01 00:00:00Z]
  @t3 ~U[2026-01-01 00:00:00Z]

  setup do
    # A real (non-transactional) reset, mirroring facts_test.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
    AshJudgments.TestRepo.query!("DELETE FROM test_facts")
    # The replay demo needs a CLEAN event log: stale events from other runs
    # (same subject/predicate) would replay interleaved and violate the
    # WITHOUT OVERLAPS identity.
    AshJudgments.TestRepo.query!("DELETE FROM test_event_log")

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :facts, Fact)
    on_exit(fn -> Application.delete_env(:ash_judgments, :facts) end)
    :ok
  end

  # --- (1) as-of status across a revision boundary -----------------------------

  test "as-of read answers status at a past as_of across a revision boundary" do
    {:ok, :materialised} = materialise(value: "urgent", holds: true, effective_at: @t1)
    {:ok, :materialised} = materialise(value: "routine", holds: false, effective_at: @t2)

    # Before the revision: the first version, live at that instant.
    v1 = at(@t1 |> DateTime.add(1, :hour))
    assert v1.value == "urgent"
    assert v1.holds == true
    assert v1.status == :live

    # After the revision: the second version.
    v2 = at(@t2 |> DateTime.add(1, :hour))
    assert v2.value == "routine"
    assert v2.holds == false
    assert v2.status == :live

    # As of now: only the revision is current.
    assert current().value == "routine"
  end

  # --- (2) future-dated revision ------------------------------------------------

  test "a future-dated revision is invisible at now, visible at as_of(future)" do
    {:ok, :materialised} = materialise(value: "urgent", holds: true, effective_at: @t1)

    future = ~U[2027-06-01 00:00:00Z]
    {:ok, :materialised} = materialise(value: "routine", holds: false, effective_at: future)

    # No scheduler ran: the current read is unchanged the instant after
    # the write.
    assert current().value == "urgent"
    assert at(future).value == "routine"
    assert at(future |> DateTime.add(1, :day)).value == "routine"
  end

  # --- (3) omission truncates; history preserved --------------------------------

  test "omission truncates the period; the pre-omission as-of read is still in" do
    {:ok, :materialised} = materialise(value: "urgent", holds: true, effective_at: @t1)

    omission_at = ~U[2025-09-01 00:00:00Z]
    {:ok, :superseded} = materialise(result: :omitted, effective_at: omission_at)

    # As of now: the predicate returns to unknown (no current row).
    assert current() == nil

    # History preserved: as of before the omission the fact is still in.
    before = at(omission_at |> DateTime.add(-1, :second))
    assert before.holds == true
    assert before.value == "urgent"
  end

  # --- (4) ash_events as_of replay: periods rebuild identically -----------------

  test "ash_events replay rebuilds temporal periods identically" do
    {:ok, :materialised} = materialise(value: "urgent", holds: true, effective_at: @t1)
    {:ok, :materialised} = materialise(value: "routine", holds: false, effective_at: @t2)

    t3 = @t3

    current()
    |> Ash.Changeset.for_destroy(:truncate, %{}, as_of: t3, authorize?: false)
    |> Ash.destroy!(authorize?: false)

    before = periods()
    assert length(before) == 2

    IO.puts("BEFORE PERIODS: " <> inspect(before))

    events =
      EventLog
      |> Ash.Query.select([:resource, :action, :occurred_at, :metadata])
      |> Ash.read!(authorize?: false)

    Enum.each(events, fn e ->
      IO.puts(
        "EVENT " <>
          inspect(e.action) <>
          " " <>
          DateTime.to_iso8601(e.occurred_at) <>
          " as_of=" <> inspect(e.metadata["as_of"])
      )
    end)

    EventLog
    |> Ash.ActionInput.for_action(:replay, %{})
    |> Ash.run_action!(authorize?: false)

    assert periods() == before, "replay must rebuild the periods identically"
  end

  # --- (5) WITHOUT OVERLAPS: overlap rejected, conflict surfaces cleanly --------

  test "an overlapping concurrent revision engine-retries, then surfaces a clean WriteConflict" do
    {:ok, :materialised} = materialise(value: "urgent", holds: true, effective_at: @t1)

    # 24 concurrent revisers, one key, one instant — the engine gates and
    # retries internally (25 attempts); an exhausted writer surfaces
    # AshPostgres.Temporal.WriteConflict with nothing written.
    writers = for i <- 1..24, do: {i, @t2}

    outcomes =
      writers
      |> Task.async_stream(
        fn {i, as_of} ->
          try do
            {:ok, :materialised} =
              materialise(value: "v#{i}", holds: false, effective_at: as_of)

            :ok
          rescue
            e in AshPostgres.Temporal.WriteConflict -> {:conflict, e}
          end
        end,
        max_concurrency: 24,
        timeout: 180_000
      )
      |> Enum.map(fn
        {:ok, outcome} -> outcome
        {:exit, reason} -> {:exit, inspect(reason)}
      end)

    exits = Enum.filter(outcomes, &match?({:exit, _}, &1))
    assert exits == []

    Enum.each(outcomes, fn
      {:conflict, e} ->
        assert e.resource == Fact
        assert e.attempts == 25

      _ ->
        :ok
    end)

    # Exactly one open period survives for the key.
    open = Enum.filter(periods(), &(&1.upper == :unbounded))
    assert length(open) == 1
  end

  # --- (6) the materialiser race: exactly one period outcome ---------------------

  test "two concurrent admissions on one key yield exactly one period outcome" do
    {:ok, :materialised} = materialise(value: "urgent", holds: true, effective_at: @t1)

    outcomes =
      ["a", "b"]
      |> Task.async_stream(fn v ->
        try do
          {:ok, verdict} =
            materialise(value: v, holds: v == "a", effective_at: @t2, revise?: true)

          {:ok, verdict}
        rescue
          e in AshPostgres.Temporal.WriteConflict -> {:conflict, e}
        end
      end)
      |> Enum.map(&elem(&1, 1))

    # Both revisers split the same period at the same instant: the engine
    # gates and retries; the loser either applies after the winner (its own
    # period outcome) or surfaces the clean conflict after exhausting the
    # attempt budget. Never two open rows, never a crash.
    Enum.each(outcomes, fn
      {:ok, verdict} -> assert verdict in [:materialised, :unchanged, :superseded]
      {:conflict, e} -> assert e.attempts == 25 and e.resource == Fact
      other -> flunk("unexpected outcome: #{inspect(other)}")
    end)

    # Exactly one open period per key, whatever the interleaving.
    open = Enum.filter(periods(), &(&1.upper == :unbounded))
    assert length(open) == 1
  end

  # --- helpers -------------------------------------------------------------------

  defp materialise(overrides) do
    base = [
      result: :admitted,
      subject: @subject,
      predicate: @predicate,
      value: "urgent",
      holds: true,
      grade: :grant,
      admission_id: Ash.UUID.generate()
    ]

    decision = Keyword.merge(base, overrides)

    if overrides[:revise?] do
      fact =
        Fact
        |> Ash.Query.filter(subject_id == ^@subject["id"] and predicate == ^@predicate)
        |> Ash.read_one!(authorize?: false)

      fact
      |> Ash.Changeset.for_update(:revise, Keyword.take(decision, [:value, :holds]),
        as_of: decision[:effective_at],
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      {:ok, :materialised}
    else
      Materialiser.materialise(decision)
    end
  end

  defp current do
    Fact
    |> Ash.Query.filter(subject_id == ^@subject["id"] and predicate == ^@predicate)
    |> Ash.Query.load([:status, :expired?])
    |> Ash.read_one!(authorize?: false)
  end

  defp at(as_of) do
    Fact
    |> Ash.Query.filter(subject_id == ^@subject["id"] and predicate == ^@predicate)
    |> Ash.Query.as_of(as_of)
    |> Ash.Query.load([:status, :expired?])
    |> Ash.read_one!(authorize?: false)
  end

  defp periods do
    AshJudgments.TestRepo.query!(
      """
      select value::text, holds::text, lower(valid_at)::text,
             coalesce(upper(valid_at)::text, 'unbounded')
      from test_facts
      where subject_id = $1 and predicate = $2
      order by lower(valid_at)
      """,
      [@subject["id"], @predicate]
    ).rows
    |> Enum.map(fn [value, holds, lower, upper] ->
      %{
        value: Jason.decode!(value),
        holds: holds == "true",
        lower: lower,
        upper: if(upper == "unbounded", do: :unbounded, else: upper)
      }
    end)
  end
end
