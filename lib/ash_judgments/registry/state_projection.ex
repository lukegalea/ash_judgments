# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.StateProjection do
  @moduledoc """
  The behaviour of a question's `state_projection` module (the `state:`
  seam, law: what the model sees is declared, not everything the caller
  holds).

  - `project/2` builds the state body sent on the wire from the action
    input and context.
  - `shape/0` (optional but the point of `state_contract`) returns the
    DECLARED output shape, as data — the canonical JSON of this value is
    what `state_contract` hashes (RFC §3.2, Q1's resolution). A projection
    refactor that does not alter the shape does not mint a new question;
    one that alters what the model can see does. When ADR 0046's single
    Ash-type-to-schema mapping lands, `shape/0` values expressed as Ash
    types render through it.
  """

  @moduledoc since: "0.1.0"

  @callback project(input :: term(), context :: map()) :: map()

  # The declared output shape hashed into `state_contract`. Optional: an
  # undeclared shape hashes as `nil` (the digest of nothing).
  @callback shape() :: term()

  @optional_callbacks [shape: 0]
end
