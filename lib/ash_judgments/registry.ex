# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry do
  @moduledoc """
  The question registry DSL — **ticket AST-87** (CORE-REGISTRY).

  Law 4: every question — and every output shape — is a declaration.
  Questions are declared in a Spark extension on an Ash resource, typed by
  Ash types, given options drawn from constraints (the same `one_of` that
  validates an attribute is the option list of a Choice), versioned and
  content-hashed; the hash is the question's identity in the ledger. Because
  the question is a declaration, the manifest, the docs, the agent tooling
  and the audit pack all see the model surface like any other contract.

  ## Scope (AST-87)

  - A Spark extension with a `judgments` section, one entity per question:
    answer type (`AshAi.Evaluate.Noul | Choice | Score`, or the package's
    `Evidence` type), constraints or `options_from {Resource, :attribute}`,
    abstain option, instructions, criteria, version, family,
    `state_projection`, `pii`, profile, `record`, `ttl`, `pin`.
  - A generated generic judge action per question (or question set), wired
    to upstream `AshAi.Actions.Evaluate` with the resolved profile.
  - Question lineage and revision-proposal records: wording may be
    machine-proposed, but a proposal is a new version (new hash) that
    re-earns calibration.

  TODO(AST-87): everything above. This module is a scaffold stub — no
  feature logic ships until the ticket lands.
  """
end
