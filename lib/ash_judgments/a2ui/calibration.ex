# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui.Calibration do
  @moduledoc """
  The calibration surface: every recorded calibration run, newest first,
  with what it measured (n, ECE and Brier), the threshold it earned at
  its family's α, the instrument, and the trigger's result (a proposed
  table, or none and why). Negative results are kept (ADR 0047), so this
  is the family's whole trajectory. Read-only.

  ## Contract

  On the calibration-run resource (`:resource`): the read `:read_action`
  (default `:read`). Narrow it on the host if some runs should not show.
  """
  @moduledoc since: "0.3.3"

  defmacro __using__(opts) do
    resource = Keyword.fetch!(opts, :resource)
    surface_id = Keyword.get(opts, :surface_id, "judgment_calibration")
    title = Keyword.get(opts, :title, "Calibration")
    read_action = Keyword.get(opts, :read_action, :read)

    quote do
      use AshA2ui.Standalone

      a2ui do
        for_resource unquote(resource)
        surface_id unquote(surface_id)
        title unquote(title)
        record_label "calibration run"
        spec_version "1.0"

        query :runs do
          search_fields [:family]
          sortable [:family, :finished_at, :n]
          default_sort finished_at: :desc
          page_size 25
        end

        component :table do
          fields([
            :family,
            :result,
            :n,
            :threshold,
            :ece,
            :brier,
            :model_version,
            :runtime_version,
            :finished_at
          ])

          read_action unquote(read_action)
          query :runs

          row_layout do
            title :family
            badge :result
            meta [:n, :threshold, :ece, :brier, :model_version, :runtime_version, :finished_at]
            columns 3
          end
        end

        field :n do
          label "n"
        end

        field :threshold do
          label "Threshold (at α)"
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

        field :runtime_version do
          label "Runtime"
        end

        field :finished_at do
          label "Finished"
        end
      end
    end
  end
end
