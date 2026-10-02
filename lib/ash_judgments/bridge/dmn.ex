# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Dmn do
  @moduledoc """
  The DMN bridge — **ticket AST-92** (CORE-BRIDGE-DMN).

  Answers are DMN inputs, never FEEL functions. A model call inside FEEL
  would break the content-hashed, TCK-verified contract, blow the evaluator
  timeouts, and make matched-rule ids non-reproducible. So this bridge only
  *flattens recorded answers* into a FEEL-ready context (Decimals
  throughout), and reads bands out of versioned DMN band tables — the only
  place a probability becomes an admission.

  Missing, abstained or replay-missed answers are explicit
  (`"present" => false`), never absent keys.

  ## Scope (AST-92)

  - `inputs(judgments, opts)` — the FEEL-ready context per answer type
    (Noul, Choice/Evidence, Score).
  - The band-table contract: outputs `band` ∈ `admitted | review | unknown`
    plus an optional `reason_code`; a naming/tagging convention marks the
    band table for a family; an example band table fixture ships with the
    package.
  - `band(judgment, opts)` — resolve the band table for (family, tenant) and
    evaluate through the host's resolver.

  Requires the optional `ash_decisions` dependency. TODO(AST-92): the
  feature logic; this stub carries only the availability contract.
  """

  @doc """
  `:ok` when the `ash_decisions` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_decisions}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_decisions}}
  def available? do
    AshJudgments.Availability.ensure(:ash_decisions)
  end
end
