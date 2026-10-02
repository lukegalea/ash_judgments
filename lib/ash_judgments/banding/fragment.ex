# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Banding.Fragment do
  @moduledoc """
  The banding record fragment (RFC §7.1) — a third host-included
  fragment beside the ledger and the facts table.

  ## Replay safety (RFC §6.1)

  The `:record` create accepts EVERY field as input, including the
  band-table's own outputs (`band`, `matched_rule_ids`, `fact_value`)
  and the `ash_decisions` evaluation id. The band-table evaluation
  happens BEFORE this create — in the host's banding step through the
  resolver seam — and the create's only change computes the pure
  `record_hash` from those inputs. No evaluation, no resolver call, no
  I/O anywhere on the create path: replay rebuilds the row from its
  inputs without consulting ash_decisions at all.

  ## Refusal is not a result

  `matched_rule_ids` empty is a refusal (ADR 0041): the host's banding
  step refuses BEFORE writing, and the fragment's verifier keeps the
  contract on the record — a stored banding with empty matched rule ids
  is a schema violation, caught at validation.

  ## Immutability

  Bandings are immutable — no update action exists. Re-banding is a new
  banding row (law 2); admissions reference the banding id.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    # The caller (the banding step) may pass a deterministic id — an
    # idempotency key for the write.
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0,
      writable?: true,
      public?: true

    create_timestamp :banded_at

    attribute :record_version, :string,
      default: "0",
      writable?: false,
      public?: true

    attribute :record_hash, :string,
      writable?: true,
      public?: true,
      description:
        "The §4.5 digest over the envelope-class fields; computed by the :record change."

    attribute :observation_ids, {:array, :uuid},
      allow_nil?: false,
      public?: true,
      description:
        "Usually one. More than one when a band table reads several answers — e.g. an extraction plus its verification."

    attribute :band, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:admit, :review, :omit]],
      description: "The band table's output (ADR 0041). The frozen enum — Q11's spelling."

    attribute :fact_value, AshJudgments.Facts.ScalarJson,
      public?: true,
      description:
        "The fact value the table proposes. Admit only — validated by the :record change."

    attribute :reason_code, :string, public?: true

    attribute :matched_rule_ids, {:array, :string},
      allow_nil?: false,
      public?: true,
      description:
        "From Evaluation.matched_rule_ids. EMPTY IS A REFUSAL, not a result (ADR 0041)."

    # §7.1 band_table: {definition_key, definition_version, content_hash,
    # definition_id, tenant_fork} — copied from the ash_decisions
    # Definition at evaluation time, through the host resolver seam.
    attribute :band_table, :map,
      allow_nil?: false,
      public?: true,
      description: "The band-table ref the evaluation ran (§7.1). Copied, never re-resolved."

    attribute :decision_evaluation_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "The ash_decisions Evaluation row (passed in — never recomputed)."

    attribute :inputs, :map,
      allow_nil?: false,
      public?: true,
      description:
        "The flattened DMN inputs (Bridge.Dmn.inputs/2 output): decimal-string probabilities, family, risk tier, jurisdiction. Envelope-class."

    attribute :mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:live, :shadow]],
      default: :live

    attribute :flags, {:array, :string},
      public?: true,
      description: "e.g. accelerator_mismatch, digest_missing, audit_sample_selected"

    attribute :correlation_id, :uuid, public?: true
  end

  actions do
    create :record do
      description """
      Records a banding. Accepts every field as input, including the
      band-table's outputs and the evaluation id — the banding is
      recorded, never recomputed (law 2, RFC §6.1).
      """

      accept [
        :id,
        :observation_ids,
        :band,
        :fact_value,
        :reason_code,
        :matched_rule_ids,
        :band_table,
        :decision_evaluation_id,
        :inputs,
        :mode,
        :flags,
        :correlation_id
      ]

      change {AshJudgments.Banding.Changes.EnforceContract, []}
    end

    defaults [:read]
  end

  validations do
    validate {AshJudgments.Banding.Validations.NonEmptyMatchedRules, []},
      description: "matched_rule_ids empty is a refusal, not a result (ADR 0041)."

    validate {AshJudgments.Banding.Validations.FactValueAdmitOnly, []},
      description: "fact_value is admit-only (§7.1)."
  end
end
