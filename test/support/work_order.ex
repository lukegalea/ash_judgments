# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.WorkOrder do
  @moduledoc """
  A synthetic constrained subject. Its `priority` attribute carries a
  `one_of` constraint, which is the exact shape the question registry DSL
  (AST-87) turns into the option list of a Choice: options drawn from
  constraints, so the declaration stays the shared schema.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "test_work_orders"
    repo(AshJudgments.TestRepo)
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :priority]
    end

    update :update do
      accept [:title, :priority]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      constraints min_length: 1
    end

    attribute :priority, :atom do
      allow_nil? false
      constraints one_of: [:low, :normal, :high]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
