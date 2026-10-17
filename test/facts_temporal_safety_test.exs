# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsTemporalSafetyTest do
  @moduledoc """
  Issue #7: every change, validation and preparation the facts fragments
  attach must declare `temporal_safe?/1`, or Ash refuses the action on a
  temporal host with `Ash.Error.Framework.NotTemporalSafe`.

  The host here is `AshJudgments.Test.PlainFact`: the temporal fragment
  with no `AshEvents.Events` extension. The main test host
  (`AshJudgments.Test.Fact`) carries that extension, and its change wrapper
  declares temporal safety on the wrapped change's behalf, which is why the
  suite never caught this.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Test.PlainFact

  @subject %{"type" => "AshJudgments.Test.Appointment", "id" => "plain-temporal-1"}
  @predicate "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"

  @t1 ~U[2025-01-10 00:00:00Z]
  @t2 ~U[2025-06-01 00:00:00Z]
  @t3 ~U[2026-01-01 00:00:00Z]

  setup tags do
    if tags[:db] do
      # A real (non-transactional) reset, mirroring facts_temporal_test.
      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)
      AshJudgments.TestRepo.query!("DELETE FROM test_facts")
      Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    end

    :ok
  end

  @tag :db
  test "materialise, revise and truncate run on a temporal host with no event log" do
    assert {:ok, :materialised} =
             Materialiser.materialise(decision(value: "urgent", holds: true, effective_at: @t1),
               resource: PlainFact
             )

    assert {:ok, :materialised} =
             Materialiser.materialise(decision(value: "routine", holds: false, effective_at: @t2),
               resource: PlainFact
             )

    assert {:ok, :superseded} =
             Materialiser.materialise(decision(result: :omitted, effective_at: @t3),
               resource: PlainFact
             )

    # The derived columns were written by the fragment's changes.
    [first] = Ash.read!(PlainFact, as_of: DateTime.add(@t1, 1, :hour), authorize?: false)
    assert first.value == "urgent"
    assert first.subject_type == "AshJudgments.Test.Appointment"
    assert first.subject_id == "plain-temporal-1"
    assert is_binary(first.scope_hash)

    [second] = Ash.read!(PlainFact, as_of: DateTime.add(@t2, 1, :hour), authorize?: false)
    assert second.value == "routine"

    assert [] == Ash.read!(PlainFact, as_of: DateTime.add(@t3, 1, :hour), authorize?: false)
  end

  @tag :db
  test "the derived columns are replay-identical: same inputs, same values" do
    inputs = %{
      subject: @subject,
      predicate: @predicate,
      value: "urgent",
      holds: true,
      scope: %{"tenant_id" => "t-1", "requirement_set" => "rs-1"},
      admission_grade: :grant
    }

    a = create!(inputs, @t1)
    b = create!(%{inputs | subject: %{@subject | "id" => "plain-temporal-2"}}, @t2)

    assert a.scope_hash == b.scope_hash
    assert a.subject_type == b.subject_type
  end

  test "every change, validation and preparation on the temporal fragment is temporal safe" do
    attached = attached_modules(PlainFact)

    # The walk is not vacuous: it reaches the fragment's own changes and
    # preparations.
    seen = MapSet.new(attached, fn {action, kind, module, _opts} -> {action, kind, module} end)
    assert {:materialise, :change, AshJudgments.Facts.Changes.DeriveSubject} in seen
    assert {:materialise, :change, AshJudgments.Facts.Changes.DeriveScopeHash} in seen
    assert {:for_subject, :preparation, AshJudgments.Facts.Preparations.ForSubject} in seen

    unsafe =
      for {action, kind, module, opts} <- attached,
          not Ash.Temporal.temporal_safe?(module, opts),
          do: {action, kind, module}

    assert unsafe == []
  end

  # --- helpers -----------------------------------------------------------------

  defp decision(overrides) do
    Keyword.merge(
      [
        result: :admitted,
        subject: @subject,
        predicate: @predicate,
        value: "urgent",
        holds: true,
        grade: :grant,
        admission_id: Ash.UUID.generate()
      ],
      overrides
    )
  end

  defp create!(inputs, as_of) do
    PlainFact
    |> Ash.Changeset.for_create(:materialise, inputs, as_of: as_of, authorize?: false)
    |> Ash.create!()
  end

  # Every change/validation/preparation module an action of `resource` runs:
  # the action's own, plus the resource-level `changes`, `validations` and
  # `preparations` blocks that apply to it.
  defp attached_modules(resource) do
    global_changes = Ash.Resource.Info.changes(resource)
    global_validations = Ash.Resource.Info.validations(resource)
    global_preparations = Ash.Resource.Info.preparations(resource)

    for action <- Ash.Resource.Info.actions(resource),
        entry <- entries(action, global_changes, global_validations, global_preparations) do
      entry
    end
  end

  defp entries(action, global_changes, global_validations, global_preparations) do
    own =
      case action.type do
        :read -> Map.get(action, :preparations, [])
        :action -> Map.get(action, :preparations, [])
        _ -> Map.get(action, :changes, [])
      end

    globals =
      if action.type == :read,
        do: global_preparations,
        else: global_changes ++ global_validations

    for item <- own ++ globals, applies_to?(item, action), entry <- unpack(action, item) do
      entry
    end
  end

  defp applies_to?(%{on: on}, action) when is_list(on), do: action.type in on
  defp applies_to?(_item, _action), do: true

  defp unpack(action, %Ash.Resource.Change{change: {module, opts}}),
    do: [{action.name, :change, module, opts}]

  defp unpack(action, %Ash.Resource.Validation{validation: {module, opts}}),
    do: [{action.name, :validation, module, opts}]

  defp unpack(action, %Ash.Resource.Preparation{preparation: {module, opts}}),
    do: [{action.name, :preparation, module, opts}]

  defp unpack(_action, _other), do: []
end
