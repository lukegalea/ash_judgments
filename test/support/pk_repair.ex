# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.PkRepair.Broken do
  @moduledoc """
  A temporal facts host as it stands when its table lacks the primary key
  the snapshot records: the `TemporalFragment` on Postgres, nothing else.
  Its domain is used only by the codegen proof in
  `AshJudgments.FactsTemporalPrimaryKeyTest`.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.PkRepair.BrokenDomain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Facts.TemporalFragment]

  postgres do
    table "pk_repair_facts"
    repo(AshJudgments.TestRepo)
  end
end

defmodule AshJudgments.Test.PkRepair.BrokenDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshJudgments.Test.PkRepair.Broken)
  end
end

defmodule AshJudgments.Test.PkRepair.Repaired do
  @moduledoc """
  The same host, same table, after the repair step: the resource gains
  the `AshJudgments.Facts.TemporalPrimaryKey` custom statement.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.PkRepair.RepairedDomain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Facts.TemporalFragment]

  postgres do
    table "pk_repair_facts"
    repo(AshJudgments.TestRepo)

    custom_statements do
      statement :pk_repair_facts_temporal_primary_key do
        up(AshJudgments.Facts.TemporalPrimaryKey.repair_up("pk_repair_facts"))
        down(AshJudgments.Facts.TemporalPrimaryKey.repair_down("pk_repair_facts"))
      end
    end
  end
end

defmodule AshJudgments.Test.PkRepair.RepairedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshJudgments.Test.PkRepair.Repaired)
  end
end
