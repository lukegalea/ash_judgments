# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.Banding.ReviewSource do
  @moduledoc """
  What a host supplies so a person reviewing a banding can read the text
  the model judged and the thresholds of the table that banded it. The
  package holds no key and no decisions store, so both reads are the
  host's:

      config :ash_judgments, :review_source, MyApp.SystemOne.ReviewSource

  The banding fragment's `:judged_text`, `:judged_excerpt` and `:lean`
  calculations (`AshJudgments.Banding.Review`) call it. Without it,
  `:judged_text` and `:judged_excerpt` are nil and `:lean` says the
  threshold is not known.

  ## `open_state/2`

  Called with the banding's observations, read from the host's ledger
  (`config :ash_judgments, :ledger`) as the actor the calculation runs
  for, each with its sealed `state_ciphertext`, and the Ash options of
  that read (`actor:`, `tenant:`, `authorize?:`). Return a map from
  observation id to the plain text, or to nil for one the actor may not
  read. Decrypt through the host's own key handling and authorize as the
  actor: the package never sees a key, and it never calls this without
  an actor.

  ## `band_table/2` (optional)

  Called with a banding record and the same options. Return `{:ok, xml}`
  with the DMN text of **the band-table version that banding recorded**
  (its `band_table` ref: `definition_id`, `definition_version`,
  `content_hash`; or the version its `decision_evaluation_id` ran), or
  `:error`. Never return the table that is published now: a later
  version can have other thresholds. The package reads the thresholds
  back with `AshJudgments.Calibration.ProposalDmn.thresholds/1`, so a
  table it did not render reads as unknown.
  """
  @moduledoc since: "0.3.3"

  @callback open_state(observations :: [Ash.Resource.record()], opts :: keyword()) ::
              %{optional(term()) => String.t() | nil}

  @callback band_table(banding :: Ash.Resource.record(), opts :: keyword()) ::
              {:ok, String.t()} | :error

  @optional_callbacks band_table: 2

  @doc "The configured review source, or nil."
  @spec configured() :: module() | nil
  def configured, do: Application.get_env(:ash_judgments, :review_source)
end
