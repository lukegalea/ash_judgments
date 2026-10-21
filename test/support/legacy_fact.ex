# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.LegacyFact do
  @moduledoc """
  A legacy facts host: the deprecated `AshJudgments.Facts.Fragment` on
  Postgres, over its own `test_legacy_facts` table, so the materialiser's
  legacy (supersede-then-create) path has a host to run against. Its
  domain is used only by `AshJudgments.FactsScopeTest`.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.LegacyFactDomain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Facts.Fragment]

  postgres do
    table "test_legacy_facts"
    repo(AshJudgments.TestRepo)
    migrate?(false)
  end
end

defmodule AshJudgments.Test.LegacyFactDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshJudgments.Test.LegacyFact)
  end
end
