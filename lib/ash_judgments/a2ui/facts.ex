# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui.Facts do
  @moduledoc """
  The facts surface: the facts current now, per subject and predicate,
  with the value, whether it holds, its status (in, out or unknown with
  the reason), the grade it was admitted at and the admission behind it.
  Search by subject. Read-only: a fact changes only through a new
  admission or a person's verdict.

  ## Contract

  On the facts resource (`:resource`): the read `:read_action` (default
  `:current`, which both facts fragments declare and which loads
  `status`).
  """
  @moduledoc since: "0.3.3"

  defmacro __using__(opts) do
    resource = Keyword.fetch!(opts, :resource)
    surface_id = Keyword.get(opts, :surface_id, "judgment_facts")
    title = Keyword.get(opts, :title, "Facts")
    read_action = Keyword.get(opts, :read_action, :current)

    quote do
      use AshA2ui.Standalone

      a2ui do
        for_resource unquote(resource)
        surface_id unquote(surface_id)
        title unquote(title)
        record_label "fact"
        spec_version "1.0"

        query :facts do
          search_fields [:subject_id, :predicate]
          sortable [:subject_id, :predicate]
          default_sort subject_id: :asc
          page_size 25
        end

        component :table do
          fields [:subject_id, :predicate, :value, :holds, :admission_grade, :admission_id]
          read_action unquote(read_action)
          query :facts

          row_layout do
            title :subject_id
            badge :holds
            meta [:predicate, :value, :admission_grade, :admission_id]
            columns 2
          end
        end

        field :subject_id do
          label "Subject"
        end

        field :admission_grade do
          label "Admitted as"
        end

        field :admission_id do
          label "Admission"
        end
      end
    end
  end
end
