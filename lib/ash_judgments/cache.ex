# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Cache do
  @moduledoc """
  Cache, replay and shadow modes — **ticket AST-89** (CORE-CACHE).

  The ledger doubles as the cache. The key is
  `sha256(model_version <> question_hash <> canonical_json(state))`.

  - **`:live`** (the default): look up by key before calling, respecting TTL
    and pinning; call on a miss; record the answer.
  - **`:replay`**: answer only from the ledger and error on a miss —
    `{:error, %ReplayMiss{}}`, never a call. Compliance re-evaluation and
    audit packs reproduce history; a replayed answer that disagrees with the
    original is worse than no answer.
  - **`:shadow`**: call a candidate profile and record with `mode: :shadow`
    and a `shadow_of` reference; compute and emit a diff. Shadow rows are
    never returned to callers and never banded. This is the model-upgrade
    path: a model upgrade is a rule change.

  ## Scope (AST-89)

  - The mode option (per call, per process, or per config).
  - TTL per family from the registry; expired rows are misses in live mode
    and still hits in replay mode.
  - Pin verification against `Result.model` with `pin_mismatch` handling.
  - A `mix ash_judgments.shadow` task re-running recorded states.

  TODO(AST-89): everything above. This module is a scaffold stub — no
  feature logic ships until the ticket lands.
  """
end
