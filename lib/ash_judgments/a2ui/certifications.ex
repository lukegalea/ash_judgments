# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui.Certifications do
  @moduledoc """
  The certifications surface: the band tables people have certified, per
  family, with the definition and version they certified and who did.
  **Revoke** withdraws one: the family then has no certified table, and
  the verifier refuses its publication until a new run is certified.

  ## Contract

  On the certification resource (`:resource`):

  - `read :certified` (`:read_action`): certifications with the status
    `:certified`. One resource, so the fragment could own it, but hosts
    narrow it differently (by tenant scope or age), so the host declares it.
  - `update :revoke` (`:revoke_action`): the fragment's revoke, run with no
    input. The fragment's revoke accepts `certified_by`, so make the host's
    action record the person revoking
    (`change set_attribute(:certified_by, actor(:email))`), and make it
    human-only.

  The surface shows `family`, `status`, `definition_key`,
  `definition_version`, `certified_by` and `certified_at`.
  """
  @moduledoc since: "0.3.3"

  defmacro __using__(opts) do
    resource = Keyword.fetch!(opts, :resource)
    surface_id = Keyword.get(opts, :surface_id, "judgment_certifications")
    title = Keyword.get(opts, :title, "Certified band tables")
    read_action = Keyword.get(opts, :read_action, :certified)
    revoke_action = Keyword.get(opts, :revoke_action, :revoke)

    quote do
      use AshA2ui.Standalone

      a2ui do
        for_resource unquote(resource)
        surface_id unquote(surface_id)
        title unquote(title)
        record_label "certification"
        spec_version "1.0"

        query :certified do
          sortable [:family, :certified_at]
          default_sort certified_at: :desc
          page_size 25
        end

        component :table do
          fields [
            :family,
            :status,
            :definition_key,
            :definition_version,
            :certified_by,
            :certified_at
          ]

          read_action unquote(read_action)
          query :certified
          row_actions [unquote(revoke_action)]

          row_layout do
            title :family
            badge :status
            meta [:definition_key, :definition_version, :certified_by, :certified_at]
            columns 2
          end
        end

        action unquote(revoke_action) do
          label "Revoke"
          visible_when status: :certified
        end

        field :definition_version do
          label "Version"
        end

        field :certified_by do
          label "Certified by"
        end

        field :certified_at do
          label "Certified"
        end
      end
    end
  end
end
