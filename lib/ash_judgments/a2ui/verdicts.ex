# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui.Verdicts do
  @moduledoc """
  The verdicts surface: judgments the band table sent to review, oldest
  first, one row per subject, question and unchanged text. Each row shows
  the question's wording, the subject, the text the model judged (cut for
  the row; **Details** shows all of it), and the model's lean in words
  ("leans yes, 0.70; 0.77 admits without review"). **Record verdict**
  asks for the person's answer, yes or no for a yes/no question, and why,
  and records it. Every verdict is a person-made calibration label for
  the question's family.

  ## Contract

  On the banding resource (`:resource`):

  - `read :awaiting_verdict` (`:read_action`): bandings in the `review`
    band with no verdict for any of their observations, one per subject,
    question and state digest. It crosses the host's verdict and judgment
    resources, so the host declares it, with the package's filter:

    ```elixir
    read :awaiting_verdict do
      prepare {AshJudgments.HumanVerdict.AwaitingVerdict,
               verdict_resource: MyApp.SystemOne.HumanVerdict,
               judgment_resource: MyApp.SystemOne.Judgment}
    end
    ```

  - `action :record_verdict` (`:verdict_action`): a generic action with
    the arguments `record_id`, `answer` and `why`, run by
    `AshJudgments.HumanVerdict.FromBanding`. Make it human-only. The
    prompt labels its inputs by their names ("Answer", "Why"). For yes/no
    questions declare the answer as a choice, so the prompt is a Yes/No
    picker rather than free text:

    ```elixir
    action :record_verdict, :map do
      argument :record_id, :uuid, allow_nil?: false
      argument :answer, :atom, allow_nil?: false, constraints: [one_of: [:yes, :no]]
      argument :why, :string

      run {AshJudgments.HumanVerdict.FromBanding,
           verdict_resource: MyApp.SystemOne.HumanVerdict,
           judgment_resource: MyApp.SystemOne.Judgment}
    end
    ```

    A host whose verdict questions are not all yes/no declares
    `argument :answer, :string`; `FromBanding` accepts both.

  - The banding fragment's display calculations, which need two pieces of
    host configuration: `config :ash_judgments, :ledger` (the judgment
    resource, which the host already sets to record judgments) and
    `config :ash_judgments, :review_source`, a module implementing
    `AshJudgments.Banding.ReviewSource`. It opens the sealed text as the
    actor and reads the thresholds of the table version each banding
    recorded. Without it the rows show no text, and the lean says the
    threshold is not known.

  The surface shows the fragment's `:question_text`, `:subject`,
  `:judged_excerpt`, `:lean`, `:question`, `:family` and `:banded_at`,
  and `:judged_text` in the detail. A row whose question was reworded
  since shows no wording (the model was asked something else); the
  question's name still identifies it.
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

        context :judgment do
          resource unquote(resource)
          picker false
        end

        query :queue do
          sortable [:banded_at]
          default_sort banded_at: :asc
          page_size 25

          empty_state title: "Nothing awaits a verdict",
                      message:
                        "Judgments the band table sends to review appear here. " <>
                          "Each verdict is recorded as a calibration label for its family."
        end

        component :table do
          fields [
            :question_text,
            :subject,
            :judged_excerpt,
            :lean,
            :question,
            :family,
            :banded_at
          ]

          read_action unquote(read_action)
          query :queue
          row_actions [unquote(verdict_action)]
          select_context :judgment

          row_layout do
            title :question_text
            meta [:subject, :judged_excerpt, :lean, :question, :family, :banded_at]
            columns 1
          end
        end

        component :detail, :judgment_detail do
          context :judgment
          fields [:question_text, :subject, :lean, :judged_text]
        end

        action unquote(verdict_action) do
          label "Record verdict"
          prompt_title "Your verdict, recorded as a calibration label"
          prompt_fields [:answer, :why]
        end

        field :question_text do
          label "Question"
        end

        field :subject do
          label "Subject"
        end

        field :judged_excerpt do
          label "What the model judged"
        end

        field :judged_text do
          label "What the model judged"
        end

        field :lean do
          label "The model"
        end

        field :question do
          label "Question id"
        end

        field :banded_at do
          label "Waiting since"
        end
      end
    end
  end
end
