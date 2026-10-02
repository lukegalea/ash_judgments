# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.Fragment do
  @moduledoc """
  The calibration-run record fragment (RFC §8.1, ticket AST-91) — the
  host-instantiated store whose rows are the §8.1 calibration runs:
  one per `(family, question_hashes, model_digest, runtime_version,
  eval_set_hash, region)` (the run key), holding the §8.1 metrics
  object — ALL NUMBERS AS DECIMAL STRINGS — the selective curve, the
  conformal thresholds at target risk with the cost matrix, and the
  provenance.

  The run's output is a PROPOSED band table (`result: :proposed_table`
  and `proposed_band_table` naming the draft definition) — recorded,
  never applied: proposals are certified by a person through
  `Banding.CertificationFragment` and published through ash_decisions'
  lifecycle. Negative results are kept (`:no_table`, `:regression` —
  ADR 0047 point 7).

  Like the ledger and banding fragments, the `:record` create accepts
  every field as input — metrics are computed BEFORE the create and
  recorded as inputs; the create's only change computes the pure
  `record_hash`. No evaluation, no model call, no I/O on the create
  path: replay rebuilds the row from its inputs without re-scoring
  anything (law 2).
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    # The caller (the harness) may pass a deterministic id — an
    # idempotency key for the write, and what makes the derived
    # record_hash replay-identical.
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0,
      writable?: true,
      public?: true

    create_timestamp :started_at

    attribute :record_version, :string,
      default: "0",
      writable?: false,
      public?: true

    attribute :record_hash, :string,
      public?: true,
      description:
        "Digest of the row's canonical JSON minus record_hash (§4.5 discipline) — computed by the :record change from inputs; identical on replay."

    ## Identity — the §8.1 run key.

    attribute :family, :string, allow_nil?: false, public?: true

    attribute :question_hashes, {:array, :string},
      allow_nil?: false,
      public?: true,
      description: "Usually one; more only for a multi-question band table."

    attribute :model_version, :string, allow_nil?: false, public?: true
    attribute :model_digest, :string, allow_nil?: false, public?: true
    attribute :runtime_version, :string, allow_nil?: false, public?: true

    attribute :eval_set_hash, :string,
      allow_nil?: false,
      public?: true,
      description: "The §8.1 eval-set reference — which labelled set the run scored."

    attribute :region, :string, allow_nil?: false, public?: true
    attribute :tenant, :string, public?: true
    attribute :risk_tier, :string, public?: true

    ## Sample sizes — what the verifier compares with the family's minimum n.

    attribute :n, :integer, allow_nil?: false, public?: true

    attribute :n_per_class, :map,
      default: %{},
      public?: true,
      description: "Per-class sample sizes on the calibration split, as integers."

    ## The §8.1 metrics object — numbers as decimal strings, always.

    attribute :metrics, :map,
      allow_nil?: false,
      public?: true,
      description:
        "Reliability bins, ECE, Brier, per-class precision/recall, selective curve — decimal strings (§8.1)."

    attribute :ece, :string, public?: true
    attribute :brier, :string, public?: true

    attribute :conformal_thresholds, :map,
      default: %{},
      public?: true,
      description:
        "At target risk α, with the cost matrix: %{\"alpha\" => %{\"threshold\" => …, \"cost\" => %{…}}} — decimal strings."

    ## Provenance and result.

    attribute :source, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:eval_set, :shadow_ledger]]

    attribute :created_by, :string, public?: true

    attribute :observations_digest, :string,
      public?: true,
      description:
        "Digest of the sorted observation ids the run scored — re-scoring reads the ledger, never re-infers (§8.1)."

    attribute :result, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:proposed_table, :no_table, :regression]],
      description: "Negative results are kept (ADR 0047 point 7)."

    attribute :proposed_band_table, :map,
      public?: true,
      description:
        "%{\"definition_key\" => …, \"definition_version\" => …} of the DRAFT table — the recorded proposal; a person certifies, ash_decisions publishes."

    attribute :pass_bar, :map,
      default: %{},
      public?: true,
      description:
        "The pre-registered pass bar and kill criteria, as declared (ADR 0047 point 7)."

    attribute :finished_at, :utc_datetime_usec, public?: true
  end

  identities do
    # Append-only history: the same run key may be re-run over time and
    # every run is kept — the identity names the slot, the record_hash
    # pins the content.
    identity :unique_id, [:id]
  end

  actions do
    create :record do
      description "Records a calibration run (§8.1). Accepts every field — computed before, recorded as inputs (law 2)."

      accept [
        :id,
        :family,
        :question_hashes,
        :model_version,
        :model_digest,
        :runtime_version,
        :eval_set_hash,
        :region,
        :tenant,
        :risk_tier,
        :n,
        :n_per_class,
        :metrics,
        :ece,
        :brier,
        :conformal_thresholds,
        :source,
        :created_by,
        :observations_digest,
        :result,
        :proposed_band_table,
        :pass_bar,
        :finished_at
      ]

      change {AshJudgments.Calibration.Changes.DeriveRun, []}
    end

    read :by_run_key do
      description "The runs for a §8.1 run key, newest first."

      argument :family, :string, allow_nil?: false, public?: true
      argument :question_hash, :string, allow_nil?: false, public?: true
      argument :model_digest, :string, allow_nil?: false, public?: true
      argument :runtime_version, :string, allow_nil?: false, public?: true
      argument :eval_set_hash, :string, allow_nil?: false, public?: true
      argument :region, :string, allow_nil?: false, public?: true

      filter expr(
               family == ^arg(:family) and
                 ^arg(:question_hash) in question_hashes and
                 model_digest == ^arg(:model_digest) and
                 runtime_version == ^arg(:runtime_version) and
                 eval_set_hash == ^arg(:eval_set_hash) and
                 region == ^arg(:region)
             )

      prepare build(sort: [started_at: :desc])
    end

    read :by_family do
      description "Every run for a family, newest first — the accumulation a proposal reads."

      argument :family, :string, allow_nil?: false, public?: true

      filter expr(family == ^arg(:family))

      prepare build(sort: [started_at: :desc])
    end

    defaults [:read]
  end
end

defmodule AshJudgments.Calibration.Changes.DeriveRun do
  @moduledoc false
  # The :record create's derived field — a PURE function of the inputs:
  # record_hash is the §4.5-style digest over the row's envelope-class
  # attributes minus record_hash itself. Identical on replay; no I/O,
  # no clock, no re-scoring (law 2).
  use Ash.Resource.Change

  alias AshJudgments.Registry.Canonical

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # id and the timestamps excluded (the ledger's discipline): the
      # hash pins the row's CONTENT — identical inputs rebuild it
      # identically whatever id carries them or when it was recorded.
      attrs =
        changeset.attributes
        |> Map.drop([:record_hash, :id, :started_at, :finished_at])

      record_hash = Canonical.digest(attrs)

      Ash.Changeset.force_change_attribute(changeset, :record_hash, record_hash)
    end)
  end
end
