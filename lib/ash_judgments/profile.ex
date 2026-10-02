# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Profile do
  @moduledoc """
  Instrument profiles — **ticket AST-86** (CORE-PROFILES).

  A profile resolves to a ReqLLM model spec: `:local` for an in-cluster
  runtime as a tuple spec with `base_url`, `:hosted` as a pinned string id.
  Each profile carries its residency (`in_cluster` | `sub_processor`), a
  region, a model digest for pinned local profiles, and a pin requirement —
  a floating tag in a compliance path is a silent policy change and is
  forbidden.

  The resolver is passed as a function, because upstream `evaluate/2`
  accepts a model argument of "a function returning one" — host code, not
  this package, resolves `{:system, var}` references at call time.

  ## Scope (AST-86)

  - The profile config schema (name, provider, model, `base_url`, `api_key`,
    residency, region, `receive_timeout`, `digest`, `pin`).
  - `Profile.model_spec/3` returning a ReqLLM spec suitable as the
    `evaluate/2` model argument, raising `FloatingAlias` for `-latest` /
    `-preview` ids where the family requires pinning.
  - A tenant residency behaviour, `ResidencyPolicy.allow?(tenant, residency,
    family)`, implemented by the host; `sub_processor` profiles are refused
    where the host policy says so (an ADR 0026 disclosure never happens by
    accident).
  - A dual contract test against the wire spec.

  TODO(AST-86): everything above. This module is a scaffold stub — no
  feature logic ships until the ticket lands.
  """
end
