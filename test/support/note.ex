# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Projections.NoteText do
  @moduledoc """
  The notes question's projection: the model sees the note text and
  nothing else. Defined above the resource it serves — the transformer
  reads `shape/0` while the resource compiles.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @impl true
  def project(input, _context), do: %{"text" => input.arguments.input["text"]}
end

defmodule AshJudgments.Test.Note do
  @moduledoc """
  A synthetic free-text subject — the kind of resource a System One question
  observes (relevance, support/contradiction, classification) but never
  writes to. Models observe; declarations decide.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAi, AshJudgments.Registry]

  judgments do
    question :notes_follow_up do
      type AshAi.Evaluate.Noul
      instructions("Does the note describe a follow-up commitment?")
      version(1)
      family(:clinic_notes)
      profile(:test_local)
      pii(:minimised)
      state_projection(AshJudgments.Test.Projections.NoteText)
      state_shape(%{"text" => "string"})
      ttl(3600)
      bpmn_callable?(true)
    end
  end

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
