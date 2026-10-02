# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Rules do
  @moduledoc """
  The `ash_rules` bridge — **ticket AST-93** (CORE-BRIDGE-RULES).

  System One is a fact producer, never an evaluator. This bridge *reads the
  ledger* and emits `{subject, predicate, value}` facts for `ash_rules`:
  a fact exists only when the latest valid banding for (subject, question)
  is `admitted` and has not expired. `review`, `unknown`, abstention,
  expiry, or no ledger row all produce **omission** — the escalate band maps
  to omitting the fact, so `missing: :unknown` blocks, and the lattice
  guarantees uncertainty can never collapse to compliant.

  The guard path must not call a model: the companion FactBuilder helper
  reads the ledger synchronously, keeping nondeterminism out of the
  transaction.

  ## Scope (AST-93)

  - `facts_from_ledger(subject, predicate_map, opts)` — facts plus the
    provenance needed for `fact_snapshot_hash` to cover the ledger ids that
    produced them.
  - The omission semantics and expiry handling above.

  Requires the optional `ash_rules` dependency. TODO(AST-93): the feature
  logic; this stub carries only the availability contract.
  """

  @doc """
  `:ok` when the `ash_rules` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_rules}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_rules}}
  def available? do
    AshJudgments.Availability.ensure(:ash_rules)
  end
end
