# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.Init do
  @moduledoc """
  Initial tables for the test support app: the synthetic subject resources.
  """

  use Ecto.Migration

  def change do
    create table(:test_notes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create table(:test_work_orders, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :title, :text, null: false
      add :priority, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
