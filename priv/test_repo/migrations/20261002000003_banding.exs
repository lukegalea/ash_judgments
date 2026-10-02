# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.BandingTables do
  @moduledoc """
  The banding and band-table-certification tables (RFC §7.1/§8.2) plus
  the modes columns the banding's create accepts.
  """

  use Ecto.Migration

  def change do
    create table(:test_bandings, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :banded_at, :utc_datetime_usec, null: false
      add :record_version, :string, null: false, default: "0"
      add :record_hash, :string

      add :observation_ids, {:array, :uuid}, null: false
      add :band, :text, null: false
      add :fact_value, :jsonb
      add :reason_code, :text
      add :matched_rule_ids, {:array, :text}, null: false
      add :band_table, :jsonb, null: false
      add :decision_evaluation_id, :uuid, null: false
      add :inputs, :jsonb, null: false
      add :mode, :text, null: false, default: "live"
      add :flags, {:array, :text}
      add :correlation_id, :uuid
    end

    create index(:test_bandings, [:observation_ids])

    create table(:test_band_table_certifications, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :certified_at, :utc_datetime_usec, null: false
      add :record_version, :string, null: false, default: "0"

      add :definition_key, :text, null: false
      add :definition_version, :text, null: false
      add :content_hash, :text, null: false
      add :family, :text, null: false
      add :tenant_scope, :text
      add :calibration_run_id, :uuid
      add :verification, :jsonb
      add :certified_by, :text, null: false
      add :status, :text, null: false, default: "certified"
    end
  end
end
