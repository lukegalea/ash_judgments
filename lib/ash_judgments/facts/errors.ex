# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.Errors.EvidenceMismatch do
  @moduledoc """
  A decision carried an evidence reference (`evidence_observation_id`, or
  a preloaded observation as `evidence_observation`) whose recorded input
  hash does not equal the decision's `subject_state_digest` (Phase 4 C1).

  The materialiser asserts the equality caller-side, pre-transaction: a
  mismatch raises this BEFORE any write, so the facts table is left
  untouched. Raised, not returned — a decision citing evidence that
  disagrees with it is a caller bug (stale or fabricated citation), not a
  runtime condition to retry (the profile-errors posture).
  """

  defexception [:predicate, :expected, :recorded, :message]

  @type t :: %__MODULE__{
          predicate: String.t(),
          expected: String.t() | nil,
          recorded: String.t() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    predicate = Keyword.fetch!(opts, :predicate)
    expected = Keyword.fetch!(opts, :expected)
    recorded = Keyword.fetch!(opts, :recorded)

    %__MODULE__{
      predicate: predicate,
      expected: expected,
      recorded: recorded,
      message:
        "evidence mismatch for predicate #{inspect(predicate)}: the observation's input_hash is " <>
          "#{inspect(expected)} but the decision records subject_state_digest #{inspect(recorded)}; " <>
          "nothing was materialised"
    }
  end
end
