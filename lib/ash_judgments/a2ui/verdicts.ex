# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui.Verdicts do
  @moduledoc """
  The verdicts surface: judgments the band table sent to review, oldest
  first, each with its family, question, the score the table read and
  the reason it was not admitted. **Record verdict** asks for the
  person's answer and a reason, and records it.

  ## Contract

  On the banding resource (`:resource`):

  - `read :awaiting_verdict` (`:read_action`): bandings in the `review`
    band with no verdict for any of their observations. It crosses the
    host's verdict resource, so the host declares it:

    ```elixir
    read :awaiting_verdict do
      filter expr(band == :review and
                  not exists(MyApp.SystemOne.HumanVerdict,
                             judgment_id in parent(observation_ids)))
    end
    ```

  - `action :record_verdict` (`:verdict_action`): a generic action with
    the arguments `record_id`, `value` and `reason`, run by
    `AshJudgments.HumanVerdict.FromBanding`. Make it human-only.

  The surface shows the fragment's `:family`, `:question`, `:score` and
  `:banded_at`, and the banding's `reason_code`.
  """
  @moduledoc since: "0.3.3"

  defmacro __using__(opts) do
    resource = Keyword.fetch!(opts, :resource)
    surface_id = Keyword.get(opts, :surface_id, "judgment_verdicts")
    title = Keyword.get(opts, :title, "Verdicts")
    read_action = Keyword.get(opts, :read_action, :awaiting_verdict)
    verdict_action = Keyword.get(opts, :verdict_action, :record_verdict)

    quote do
      use AshA2ui.Standalone

      a2ui do
        for_resource unquote(resource)
        surface_id unquote(surface_id)
        title unquote(title)
        record_label "judgment"
        spec_version "1.0"

        query :queue do
          sortable [:banded_at]
          default_sort banded_at: :asc
          page_size 25
        end

        component :table do
          fields [:question, :family, :score, :reason_code, :banded_at]
          read_action unquote(read_action)
          query :queue
          row_actions [unquote(verdict_action)]

          row_layout do
            title :question
            meta [:family, :score, :reason_code, :banded_at]
            columns 2
          end
        end

        action unquote(verdict_action) do
          label "Record verdict"
          prompt_title "Your verdict"
          prompt_fields [:value, :reason]
        end

        field :score do
          label "Model's score"
        end

        field :reason_code do
          label "Why it is in review"
        end

        field :banded_at do
          label "Waiting since"
        end
      end
    end
  end
end
