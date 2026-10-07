# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Fact do
  @moduledoc """
  The test host's materialised-facts table: the TEMPORAL Facts fragment
  (AST-147) on the host's own base (Postgres + AshEvents audit), the same
  shape a real host builds. Its `subject`/`predicate`/`value` attributes are the
  AshRules.Evaluator.Set resource contract (S1-54), so the set evaluator
  can run over this table directly in a host's integration tests.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Facts.TemporalFragment]

  events do
    event_log(AshJudgments.Test.EventLog)
    create_timestamp :recorded_at
  end

  postgres do
    table "test_facts"
    repo(AshJudgments.TestRepo)
  end
end
