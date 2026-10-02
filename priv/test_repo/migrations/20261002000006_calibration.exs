# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The calibration store (RFC §8.1, AST-91): the run record and the
# per-family accumulation of labelled pairs. New tables — no record
# change (frozen v0 untouched).

defmodule AshJudgments.Repo.Migrations.Calibration do
  use Ecto.Migration

  def up do
    create table(:test_calibration_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :record_version, :text, null: false, default: "0"
      add :record_hash, :text
      add :started_at, :utc_datetime_usec, null: false
      add :family, :text, null: false
      add :question_hashes, {:array, :text}, null: false
      add :model_version, :text, null: false
      add :model_digest, :text, null: false
      add :runtime_version, :text, null: false
      add :eval_set_hash, :text, null: false
      add :region, :text, null: false
      add :tenant, :text
      add :risk_tier, :text
      add :n, :integer, null: false
      add :n_per_class, :map, default: %{}
      add :metrics, :map, null: false
      add :ece, :text
      add :brier, :text
      add :conformal_thresholds, :map, default: %{}
      add :source, :text, null: false
      add :created_by, :text
      add :observations_digest, :text
      add :result, :text, null: false
      add :proposed_band_table, :map
      add :pass_bar, :map, default: %{}
      add :finished_at, :utc_datetime_usec
    end

    create table(:test_calibration_samples, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :record_version, :text, null: false, default: "0"
      add :added_at, :utc_datetime_usec, null: false
      add :family, :text, null: false
      add :question_hash, :text, null: false
      add :model_digest, :text, null: false
      add :runtime_version, :text, null: false
      add :region, :text, null: false
      add :tenant, :text
      add :observation_id, :uuid, null: false
      add :pair_digest, :text, null: false
      add :gold_label_digest, :text
    end

    create unique_index(:test_calibration_samples, [
             :observation_id,
             :question_hash,
             :model_digest,
             :region
           ])
  end

  def down do
    drop table(:test_calibration_samples)
    drop table(:test_calibration_runs)
  end
end
