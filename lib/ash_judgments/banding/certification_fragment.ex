# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Banding.CertificationFragment do
  @moduledoc """
  The band-table certification record fragment (RFC §8.2) — the
  judgment-side half: WHICH band-table definition is certified for WHICH
  question family, against WHICH calibration run, and what its
  verification found.

  Activation stays `ash_decisions`' lifecycle (publish/retire) — a
  certification never activates anything; it is the record a host's
  admission path checks before an automation principal's grant admits
  from a band table (ADR 0043: the grant must name a question version
  whose calibration satisfies the optimise-split rule).

  Like the banding fragment, the `:record` create accepts every field as
  input — the certification is recorded, never recomputed (law 2).
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    uuid_primary_key :id

    create_timestamp :certified_at

    attribute :record_version, :string,
      default: "0",
      writable?: false,
      public?: true

    # WHAT is certified: the band-table definition.
    attribute :definition_key, :string, allow_nil?: false, public?: true
    attribute :definition_version, :string, allow_nil?: false, public?: true

    attribute :content_hash, :string,
      allow_nil?: false,
      public?: true,
      description: "The definition's content hash — copied from the ash_decisions Definition."

    # FOR WHOM: the question family and (optionally) the tenant scope.
    attribute :family, :string, allow_nil?: false, public?: true
    attribute :tenant_scope, :string, public?: true

    # ON WHAT EVIDENCE: the calibration run the certification rests on.
    attribute :calibration_run_id, :uuid,
      public?: true,
      description:
        "The calibration run (§8.1) whose metrics satisfy the optimise-split rule (ADR 0043)."

    attribute :verification, :map,
      public?: true,
      description:
        "The §8.2 verification result as data: checks run, findings, obligations. Copied from the verifier — never recomputed."

    attribute :certified_by, :string,
      allow_nil?: false,
      public?: true,
      description:
        "Who certified (an input — the author of record; the host's policies gate claims)."

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:certified, :revoked]],
      default: :certified,
      description:
        "Revoking is a new row with status :revoked — certifications are superseded, never edited."
  end

  actions do
    create :record do
      description "Records a band-table certification for a question family (RFC §8.2)."
      accept [:*]
    end

    update :revoke do
      description "Revokes the certification — a superseding decision (recorded, never recomputed)."
      accept [:certified_by]

      # Revocation is a status change on an otherwise immutable record —
      # a pure set, no I/O (law 2). A named module, because Spark lifts
      # anonymous fns to generated modules whose names churn.
      change {AshJudgments.Banding.Changes.Revoke, []}
    end

    defaults [:read]
  end

  defmodule AshJudgments.Banding.Changes.Revoke do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.force_change_attribute(changeset, :status, :revoked)
    end
  end
end
