# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.Explore do
  @moduledoc """
  The explore tier's host-side schema (S1-56, design §1/§4):

  - **The [L]5 ordering index** — partial on
    `(question_id, subject_type, subject_id, recorded_at desc)` where
    `mode = 'live'`, the read `:latest_answered` rides. At this host's
    field set every recorded row is an answered observation, so
    live+answered reduces to `mode = 'live'`; a host carrying the §5.5
    `outcome` column adds `and outcome = 'answered'`. The index leads
    with the host's TENANT attribute when the host runs attribute
    multitenancy; this test host keeps tenant scope at the event-log
    level, so the tenant column is its.
  - **The A6 widening** — `family` loses its NOT NULL: NULL exactly on an
    exploratory observation (§7.4 n.5; the fragment's validation ties
    null to the reserved namespace). Isolated and revertible: the down is
    the generated revert of the modify, and it can only fail if
    exploratory rows exist — rows this change introduced.
  - **The proposal record** — the `test_question_proposals` table behind
    `AshJudgments.Exploration.ProposalFragment` (the person-promote
    mint's home; the wire-hash identity is unique — the detector
    proposes once).
  """

  use Ecto.Migration

  def change do
    alter table(:test_judgments) do
      modify :family, :text, null: true, from: :text
    end

    create index(:test_judgments, [:question_id, :subject_type, :subject_id, desc: :recorded_at],
             where: "mode = 'live'",
             name: :test_judgments_latest_live_answers_index
           )

    create table(:test_question_proposals, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :proposed_at, :utc_datetime_usec, null: false
      add :record_version, :string, null: false, default: "0"
      add :record_hash, :string

      add :question_id, :text, null: false
      add :question_hash, :text, null: false
      add :identity, :map, null: false
      add :wire_question_hash, :text, null: false
      add :wire_question_hashes, {:array, :text}, null: false

      add :invocation_count, :integer, null: false
      add :actor_count, :integer, null: false
      add :observation_count, :integer
      add :answer_distribution, :map
      add :subject_sample, {:array, :text}

      add :proposer, :map, null: false
      add :metadata, :map
      add :region, :text, null: false
      add :tenant, :text
    end

    create unique_index(:test_question_proposals, [:wire_question_hash])
  end
end
