# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.LegacyFacts do
  @moduledoc """
  A facts table in the legacy `AshJudgments.Facts.Fragment` shape (the
  `test_facts` table as it stood before the temporal conversion), for the
  test host `AshJudgments.Test.LegacyFact`. It gives the materialiser's
  legacy supersede-then-create path a table to run against (issue #13).
  """

  use Ecto.Migration

  def change do
    create table(:test_legacy_facts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :recorded_at, :utc_datetime_usec, null: false

      add :subject, :map, null: false
      add :subject_type, :text, null: false
      add :subject_id, :text, null: false

      add :predicate, :text, null: false
      add :value, :text, null: false
      add :holds, :boolean, null: false

      add :scope, :map
      add :subject_state_digest, :text
      add :valid_until, :utc_datetime_usec

      add :admission_grade, :text, null: false
      add :admission_id, :uuid
      add :superseded_by, :uuid
    end

    create index(:test_legacy_facts, [:predicate, :subject_type, :subject_id])
  end
end
