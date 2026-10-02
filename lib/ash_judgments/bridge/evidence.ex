# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Evidence do
  @moduledoc """
  The evidence bridge — **ticket AST-95** (CORE-BRIDGE-EVIDENCE).

  Maps a judgment (and its banding) onto an `AshCompliance` EvidenceArtifact
  create input, keeping the OSCAL method set closed: `method: :examine`,
  `collector: "systemone:<model_version>@<runtime_version>"`, `hash` the
  document hash, and `chain_of_custody` entries
  `{judgment_id, banding_id, question_hash, band_table_hash, admitted_by}`.
  No artifact attribute ever carries document text.

  ## Scope (AST-95)

  - `artifact_attrs(judgment, banding, opts)` — the create input above.
  - An OSCAL export check: the export of such an artifact stays schema-valid
    and names the model in the collector field.
  - The convention decision recorded in the ash_compliance docs.

  Requires the optional `ash_compliance` dependency. TODO(AST-95): the
  feature logic; this stub carries only the availability contract.
  """

  @doc """
  `:ok` when the `ash_compliance` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_compliance}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_compliance}}
  def available? do
    AshJudgments.Availability.ensure(:ash_compliance)
  end
end
