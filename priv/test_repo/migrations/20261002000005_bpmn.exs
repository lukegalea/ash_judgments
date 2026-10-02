# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The six core BPMN engine tables with the default resource table names,
# consolidated from ash_bpmn's own test repo migrations (core six + token
# routing + waiting state + trigger depth + parent/supersede). The engine
# resources instantiate on our repo with the defaults, so the names match.
# TEST-ONLY: ash_bpmn is a dev/test-only optional dep.

defmodule AshJudgments.Repo.Migrations.Bpmn do
  use Ecto.Migration

  def up do
    create table(:bpmn_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :key, :text, null: false
      add :name, :text, null: false
      add :version, :integer, null: false
      add :status, :text, null: false, default: "draft"
      add :xml, :text, null: false
      add :graph, :map, default: nil
      add :errors, {:array, :map}, default: []
      add :content_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:bpmn_definitions, [:key, :version])
    create unique_index(:bpmn_definitions, [:key, :status], where: "status = 'draft'")

    create table(:bpmn_instances, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :definition_id, :uuid, null: false
      add :subject_type, :text, null: false
      add :subject_id, :uuid, null: false
      add :correlation_id, :text
      add :status, :text, null: false, default: "running"
      add :started_by_id, :uuid
      add :outcome, :text
      add :trigger_depth, :integer, null: false, default: 0
      add :parent_instance_id, :uuid
      add :parent_token_id, :uuid
      add :superseded_by_instance_id, :uuid
      add :superseded_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:bpmn_instances, [:parent_token_id])
    create index(:bpmn_instances, [:superseded_by_instance_id],
             where: "superseded_by_instance_id IS NOT NULL"
           )

    create table(:bpmn_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :instance_id, :uuid, null: false
      add :node_id, :text, null: false
      add :status, :text, null: false, default: "active"
      add :routing, :map, null: false, default: fragment("'{}'::jsonb")
      add :parent_token_id, :uuid
      add :fork_id, :uuid
      add :attempts, :integer, null: false, default: 0
      add :parked_at, :utc_datetime_usec
      add :correlation_key, :text
      add :subscription_signature, :text
      add :lookback_until, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:bpmn_tokens, [:subscription_signature, :instance_id],
             where: "status = 'waiting'"
           )

    create table(:bpmn_human_tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :instance_id, :uuid
      add :token_id, :uuid
      add :node_id, :text, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "open"
      add :assignee_type, :text
      add :assignee_id, :uuid
      add :claimed_at, :utc_datetime_usec
      add :due_at, :utc_datetime_usec
      add :outcome, :text
      add :decided_by_id, :uuid
      add :delegated_from_id, :uuid
      add :timer_job_ids, {:array, :integer}, default: []
      add :comment, :text
      add :on_complete, :map, default: %{}
      add :subject_type, :text
      add :subject_id, :uuid
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:bpmn_human_tasks, [:subject_type, :subject_id, :node_id],
             where: "status IN ('open','claimed')"
           )

    create table(:bpmn_task_candidates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :task_id, :uuid, null: false
      add :principal_type, :text, null: false
      add :principal_id, :uuid, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:bpmn_task_candidates, [:task_id, :principal_type, :principal_id])

    create table(:bpmn_process_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :instance_id, :uuid
      add :token_id, :uuid
      add :node_id, :text
      add :task_id, :uuid
      add :kind, :text, null: false
      add :data, :map, default: %{}
      add :recorded_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:bpmn_process_events, [:instance_id])
  end

  def down do
    drop table(:bpmn_process_events)
    drop table(:bpmn_task_candidates)
    drop table(:bpmn_human_tasks)
    drop table(:bpmn_tokens)
    drop table(:bpmn_instances)
    drop table(:bpmn_definitions)
  end
end
