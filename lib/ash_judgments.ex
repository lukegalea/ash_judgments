# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments do
  @moduledoc """
  The System One judgment substrate for Ash.

  Every probabilistic judgment in the platform — about a clause in a
  document, an agent's intended tool call, a candidate in a search — is the
  answer to a *declared, typed question*, produced by a *replaceable
  instrument*, recorded as an *observation* with full provenance, and turned
  into anything authoritative only by a *deterministic declaration* (a DMN
  band table, an `ash_rules` bundle, an Ash action held by an actor with a
  grant). Models observe; declarations decide.

  ## What this package owns

  - **Instrument profiles** (`AshJudgments.Profile`) — local-first, residency-carrying
    ReqLLM model specs, with pinning (AST-86).
  - **The question registry DSL** (`AshJudgments.Registry`) — questions as declarations,
    typed by Ash types, options drawn from constraints, content-hashed (AST-87).
  - **The judgment ledger** (`AshJudgments.Ledger`) — a resource fragment the host
    includes, so the host's audit, tenancy and ownership apply (AST-88).
  - **Cache / replay / shadow modes** (`AshJudgments.Cache`) — the ledger doubles as
    the cache (AST-89).
  - **Telemetry** (`AshJudgments.Telemetry`) — every judgment observable with region,
    residency and disclosure data (AST-90).
  - **Calibration** (`AshJudgments.Calibration`) — the store, metrics and band-table
    proposals that earn a threshold (AST-91).
  - **Bridges** (`AshJudgments.Bridge.Dmn`, `.Rules`, `.Bpmn`, `.Evidence`) — recorded
    judgments as DMN inputs, rule facts, process signals and evidence artifacts
    (AST-92..AST-95).

  Transport is upstream `AshAi.Actions.Evaluate` over ReqLLM. This package
  ships **no HTTP client, no provider behaviour, no answer types** — upstream
  owns all three (`AshAi.Evaluate.Answer` and its `Noul`, `Choice`, `Score`,
  `Judgments` implementations).

  ## What it never does

  - It never calls a model inside checks, FEEL, rules or projectors.
  - It never holds thresholds in config.
  - It never stores policy.

  See the README for the full contract and `usage-rules.md` for the rules
  that sync into a consumer's AGENTS.md.
  """
end
