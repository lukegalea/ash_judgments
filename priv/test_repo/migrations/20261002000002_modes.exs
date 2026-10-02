# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.Modes do
  @moduledoc """
  The execution-mode columns: the wire question hash (the §4.4 cache key's
  call identifier) and the shadow reference (§5.6).
  """

  use Ecto.Migration

  def change do
    alter table(:test_judgments) do
      add :wire_question_hash, :text
      add :shadow_of, :uuid
    end

    create index(:test_judgments, [:cache_key, :recorded_at])
  end
end
