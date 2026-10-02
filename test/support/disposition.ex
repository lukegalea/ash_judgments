# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Disposition do
  @moduledoc """
  The synthetic disposition enum for the instrument probe: the
  `Ash.Type.Enum` whose values are the Choice's options — the exact shape
  the question registry (AST-87) draws `options_from`.
  """

  use Ash.Type.Enum,
    values: [:supports, :contradicts, :insufficient]
end
