# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Bpmn do
  @moduledoc """
  The BPMN bridge — **ticket AST-94** (CORE-BRIDGE-BPMN).

  The `ash:call` service task binds to a domain callables allowlist and runs
  through `Ash.run_action`, so an evaluate action can be a callable with no
  engine change. But answer structs cannot be promoted onto a token —
  promoted signals must be flat scalars — so this bridge generates
  `judge_<name>_signals` callables for questions declaring
  `bpmn_callable? true`, returning string-keyed, scalar-valued maps
  (`"<q>_p"`, `"<q>_value"`, `"<q>_confidence"`, `"<q>_judgment_id"`). The
  token carries promoted scalars; the ledger row is the full record.

  ## Scope (AST-94)

  - Generated signal callables and the documented `promote` snippet for the
    BPMN XML.
  - An example standing-evaluation process fixture (timer/message start →
    judge-signals call → band-table business rule task → gateway on band →
    human review lane → end).
  - An integration test running the fixture through the `ash_bpmn`
    interpreter in the test support app.

  Requires the optional `ash_bpmn` dependency. TODO(AST-94): the feature
  logic; this stub carries only the availability contract.
  """

  @doc """
  `:ok` when the `ash_bpmn` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_bpmn}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_bpmn}}
  def available? do
    AshJudgments.Availability.ensure(:ash_bpmn)
  end
end
