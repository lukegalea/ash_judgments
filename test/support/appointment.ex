# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Urgency do
  @moduledoc """
  The synthetic triage-urgency enum: the attribute constraint whose values
  become a Choice question's options via `options_from` (CORE-REGISTRY/AC-1).
  """

  use Ash.Type.Enum,
    values: [:emergency, :urgent, :soon, :routine]
end

defmodule AshJudgments.Test.Projections.AppointmentTriage do
  @moduledoc """
  The triage question's state projection: the model sees the appointment's
  reason, never its identifiers.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @impl true
  def project(input, _context), do: %{"reason" => input.arguments.input["reason"]}
end

defmodule AshJudgments.Test.Appointment do
  @moduledoc """
  A synthetic subject carrying a constrained attribute, with a declared
  triage question over it.

  Simple data layer: the judgments section and the generated judge actions
  need no persistence, and the fixture exists to exercise the registry.
  Nothing here is customer-related.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshAi, AshJudgments.Registry]

  judgments do
    question :triage_urgency do
      type AshAi.Evaluate.Choice
      options_from({AshJudgments.Test.Appointment, :triage_urgency})
      instructions("Which triage band does this appointment need?")

      criteria(%{
        emergency: "Immediate clinical attention",
        routine: "Can wait for the next cycle"
      })

      version(1)
      family(:clinic_triage)
      profile(:test_local)
      state_projection(AshJudgments.Test.Projections.AppointmentTriage)
      state_shape(%{"reason" => "string"})
      expose_as_tool?(true)
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :triage_urgency]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      constraints min_length: 1
    end

    attribute :triage_urgency, AshJudgments.Test.Urgency do
      allow_nil? false
    end
  end
end
