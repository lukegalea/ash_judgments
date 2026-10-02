# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Note do
  @moduledoc """
  A synthetic free-text subject — the kind of resource a System One question
  observes (relevance, support/contradiction, classification) but never
  writes to. Models observe; declarations decide.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "test_notes"
    repo(AshJudgments.TestRepo)
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:body]
    end

    update :update do
      accept [:body]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      allow_nil? false
      constraints min_length: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
