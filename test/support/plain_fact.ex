# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.PlainFact do
  @moduledoc """
  A temporal facts host with no event log: the `TemporalFragment` on
  Postgres, without the `AshEvents.Events` extension. It reads and writes
  the same `test_facts` table as `AshJudgments.Test.Fact`.

  `AshJudgments.Test.Fact` cannot catch a change that fails to declare
  `temporal_safe?/1`, because `AshEvents.Events` wraps every change in
  `AshEvents.Events.ReplayChangeWrapper`, and that wrapper declares itself
  temporal safe on the inner change's behalf. A host without an event log
  runs the fragment's changes directly, so Ash's temporal-safety check
  sees them. This resource is that host (issue #7).
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Facts.TemporalFragment]

  postgres do
    table "test_facts"
    repo(AshJudgments.TestRepo)
    migrate?(false)
  end
end
