# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.SupportAppTest do
  # The test support app: a real Ash domain on a real PostgreSQL, the same
  # shape a host ledger resource will sit on (CORE-LEDGER). Excluded entirely
  # under SKIP_DB=1.
  use ExUnit.Case, async: true

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
  end

  test "a synthetic subject round-trips through the domain" do
    note =
      AshJudgments.Test.Note
      |> Ash.Changeset.for_create(:create, %{
        body: "synthetic fixture text — no customer content, ever"
      })
      |> Ash.create!()

    assert Ash.get!(AshJudgments.Test.Note, note.id).body =~ "synthetic"
  end

  test "the constrained subject enforces its one_of — the shape Choice options are drawn from" do
    order =
      AshJudgments.Test.WorkOrder
      |> Ash.Changeset.for_create(:create, %{title: "synthetic work order", priority: :high})
      |> Ash.create!()

    assert order.priority == :high

    assert_raise Ash.Error.Invalid, fn ->
      AshJudgments.Test.WorkOrder
      |> Ash.Changeset.for_create(:create, %{title: "synthetic work order", priority: :urgent})
      |> Ash.create!()
    end
  end
end
