# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Ledger do
  @moduledoc """
  The judgment ledger — **ticket AST-88** (CORE-LEDGER).

  A model answer is an observation with a timestamp and instrument version
  (law 2: record, don't recompute). The ledger is provided as a
  `Spark.Dsl.Fragment` supplying the attributes, identities and actions; the
  **host** includes it in a resource defined on its own platform base, so
  the host's audit, tenancy and ownership apply. This package never defines
  the persisted resource itself.

  The replay hazard this design exists for: during `AshEvents` replay a
  change's `change/3` still runs, and `AshEvents` wraps only create, update
  and destroy. So the ledger create **accepts the answer as input** and
  never calls the model inside `change/3` — that is law 2, and it is what
  makes a judgment auditable.

  ## Scope (AST-88)

  - `Ledger.Fragment`: question identity (`question_id`, `question_hash`,
    `question_version`, `family`), subject refs, state digest/ref,
    answer (`answer_kind`, `value`, `probabilities`, `confidence`),
    instrument (`model_spec`, `model_version`, `model_digest`,
    `runtime_version`), context (`region`, `mode`, zone/data class,
    residency), and the wire-schema hash — per the frozen judgment-record
    RFC.
  - A replay-safe create action; record policy (compliance fails closed,
    tooling is best-effort).
  - Human verdict events: (question id and version, state ref, model answer,
    model version, human verdict) — the eval and fine-tune corpus.

  TODO(AST-88): everything above. This module is a scaffold stub — no
  feature logic ships until the ticket lands.
  """
end
