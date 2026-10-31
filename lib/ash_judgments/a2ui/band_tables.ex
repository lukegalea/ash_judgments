# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui.BandTables do
  @moduledoc """
  The band-table proposals surface: calibration runs whose trigger
  proposed a band table that no one has certified yet, with what the run
  earned (n, the threshold at the family's α, ECE and Brier) and the
  instrument it was measured on. **Certify and publish** is the person's
  certification (ADR 0041), and the publication that follows it.

  ## Contract

  On the calibration-run resource (`:resource`):

  - `read :awaiting_certification` (`:read_action`): runs with the result
    `:proposed_table` and no certification for the proposed definition.
    It crosses the host's certification resource, so the host declares it.
  - `action :certify_and_publish` (`:certify_action`): a generic action
    with the argument `record_id`. It is the host's, because publication
    is host machinery: render the proposal (`AshJudgments.Calibration.ProposalDmn`),
    save the draft in the host's decisions store, record the certification
    as the actor, and publish. A verifier refusal should come back as the
    action's error, which the surface shows. Make it human-only.

  The surface shows the fragment's `:threshold` and `:threshold_low`
  calculations (the lower one is blank when the run earned none) and the run's
  `family`, `n`, `ece`, `brier`, `model_version` and `finished_at`.
  """
  @moduledoc since: "0.3.3"

  defmacro __using__(opts) do
    resource = Keyword.fetch!(opts, :resource)
    surface_id = Keyword.get(opts, :surface_id, "judgment_band_tables")
    title = Keyword.get(opts, :title, "Band tables to certify")
    read_action = Keyword.get(opts, :read_action, :awaiting_certification)
    certify_action = Keyword.get(opts, :certify_action, :certify_and_publish)

    quote do
      use AshA2ui.Standalone

      a2ui do
        for_resource unquote(resource)
        surface_id unquote(surface_id)
        title unquote(title)
        record_label "proposed band table"
        spec_version "1.0"

        query :proposals do
          sortable [:family, :finished_at]
          default_sort finished_at: :asc
          page_size 25
        end

        component :table do
          fields [
            :family,
            :n,
            :threshold,
            :threshold_low,
            :ece,
            :brier,
            :model_version,
            :finished_at
          ]

          read_action unquote(read_action)
          query :proposals
          row_actions [unquote(certify_action)]

          row_layout do
            title :family
            meta [:n, :threshold, :threshold_low, :ece, :brier, :model_version, :finished_at]
            columns 3
          end
        end

        action unquote(certify_action) do
          label "Certify and publish"
          visible_when result: :proposed_table
        end

        field :n do
          label "Calibration n"
        end

        field :threshold do
          label "Threshold (at α)"
        end

        field :threshold_low do
          label "Lower threshold (at α)"
        end

        field :ece do
          label "ECE"
        end

        field :brier do
          label "Brier"
        end

        field :model_version do
          label "Model"
        end

        field :finished_at do
          label "Run finished"
        end
      end
    end
  end
end
