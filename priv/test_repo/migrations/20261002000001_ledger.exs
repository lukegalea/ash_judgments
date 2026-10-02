# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.Ledger do
  @moduledoc """
  The test host's ledger tables: the judgment observation store, the
  human-verdict store, and the AshEvents event log that audits both.
  """

  use Ecto.Migration

  def change do
    create table(:test_judgments, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :recorded_at, :utc_datetime_usec, null: false
      add :record_version, :string, null: false, default: "0"
      add :record_hash, :string

      add :question_id, :text, null: false
      add :question_hash, :text, null: false
      add :question_version, :integer, null: false
      add :family, :text, null: false

      add :subject_type, :text
      add :subject_id, :text
      add :rule_id, :text
      add :predicate_id, :text
      add :atom_ids, {:array, :text}
      add :document_hash, :text
      add :parser_version, :text

      add :state_digest, :text, null: false
      add :state_ref, :map
      add :state_ciphertext, :binary

      add :answer_kind, :text, null: false
      add :value, :text
      add :probabilities, :map
      add :confidence, :decimal

      add :model_spec_requested, :text, null: false
      add :model_version, :text
      add :model_digest, :text
      add :runtime_version, :text
      add :profile, :text, null: false
      add :residency, :text, null: false, default: "in_cluster"

      add :usage, :map
      add :latency_us, :integer
      add :cache_key, :text, null: false
      add :mode, :text, null: false, default: "live"
      add :region, :text, null: false
      add :correlation_id, :uuid

      add :envelope, :map

      add :valid_until, :utc_datetime_usec
    end

    create index(:test_judgments, [:cache_key])
    create index(:test_judgments, [:subject_type, :subject_id])

    create table(:test_human_verdicts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :recorded_at, :utc_datetime_usec, null: false

      add :judgment_id, :uuid, null: false
      add :question_hash, :text, null: false
      add :question_version, :integer
      add :model_digest, :text
      add :state_ref, :map
      add :model_answer, :map, null: false
      add :model_version, :text
      add :human_value, :text, null: false
      add :reason, :text
      add :reviewer, :text, null: false
      add :"blind?", :boolean, null: false, default: false
      add :basis, :text, null: false, default: "override"
    end

    create table(:test_event_log, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :record_id, :uuid, null: false
      add :resource, :text, null: false
      add :action, :text, null: false
      add :action_type, :text, null: false
      add :version, :integer, null: false
      add :data, :map, null: false
      add :changed_attributes, :map
      add :metadata, :map
      add :actor, :map
      add :tenant, :text
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:test_event_log, [:record_id])

    create table(:test_facts, primary_key: false) do
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

    # §7.4 normative 4: the set evaluator's plans read by predicate and
    # subject; a partial index on current facts is the host's tuning.
    create index(:test_facts, [:predicate, :subject_type, :subject_id])
    create index(:test_facts, [:subject])
  end
end
