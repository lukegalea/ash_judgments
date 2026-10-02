# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Domain do
  @moduledoc """
  The Ash domain of the test support app.

  A fixture, not an application domain: synthetic resources that give the
  later CORE tickets a subject to judge and a constraint to derive question
  options from. Nothing here is customer-related; nothing here lands in a
  host's domain config.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshJudgments.Test.Note
    resource AshJudgments.Test.WorkOrder
  end
end
