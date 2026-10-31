# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.Lineage do
  @moduledoc """
  Optional agent-run lineage on the test host's ledger: run, step,
  tool-call and invocation ids and the release manifest. All nullable.
  """

  use Ecto.Migration

  def change do
    alter table(:test_judgments) do
      add :run_id, :text
      add :step_id, :text
      add :tool_call_id, :text
      add :invocation_id, :text
      add :release_manifest, :text
    end
  end
end
