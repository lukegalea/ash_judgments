# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration.SampleFragment do
  @moduledoc """
  The per-family calibration accumulation — one APPEND-ONLY row per
  labelled pair added to a `(family, question_hash, model_digest,
  runtime_version, region)` slot (S1-62's live accumulation).

  The gold label itself is payload-class (the labelled text lives in the
  zone's evaluation store, never in the record — §8.1): a sample row
  carries the pair's DIGEST and the observation id it scored, and n is
  the count of rows for the slot. The band-table proposal trigger reads
  that count against the family's `min_n` (`Calibration.FamilyConfig`).
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    uuid_primary_key :id

    create_timestamp :added_at

    attribute :record_version, :string,
      default: "0",
      writable?: false,
      public?: true

    ## The accumulation slot — the run key minus the eval set (live pairs
    ## accumulate across eval sets; a run scores ONE set).

    attribute :family, :string, allow_nil?: false, public?: true
    attribute :question_hash, :string, allow_nil?: false, public?: true
    attribute :model_digest, :string, allow_nil?: false, public?: true
    attribute :runtime_version, :string, allow_nil?: false, public?: true
    attribute :region, :string, allow_nil?: false, public?: true
    attribute :tenant, :string, public?: true

    ## The pair.

    attribute :observation_id, :uuid,
      allow_nil?: false,
      public?: true,
      description:
        "The observation the pair scores — re-scoring reads the ledger, never re-infers."

    attribute :pair_digest, :string,
      allow_nil?: false,
      public?: true,
      description:
        "Digest over (observation id, gold label) — the label itself stays in the evaluation store (§8.1: labelled text never in the record)."

    attribute :gold_label_digest, :string,
      public?: true,
      description: "Digest of the gold label alone — provable without carrying the label."
  end

  identities do
    # One pair, once: the observation id pins the row per slot (a
    # re-labelled observation is a new pair, appended).
    identity :unique_observation, [:observation_id, :question_hash, :model_digest, :region]
  end

  actions do
    create :record do
      description "Appends one labelled pair to the family's accumulation (append-only)."
      accept [:*]
    end

    read :count_for do
      description "The slot's n — the accumulation count a proposal trigger reads."

      argument :family, :string, allow_nil?: false, public?: true
      argument :question_hash, :string, allow_nil?: false, public?: true
      argument :model_digest, :string, allow_nil?: false, public?: true
      argument :runtime_version, :string, allow_nil?: false, public?: true
      argument :region, :string, allow_nil?: false, public?: true

      filter expr(
               family == ^arg(:family) and
                 question_hash == ^arg(:question_hash) and
                 model_digest == ^arg(:model_digest) and
                 runtime_version == ^arg(:runtime_version) and
                 region == ^arg(:region)
             )
    end

    defaults [:read]
  end
end
