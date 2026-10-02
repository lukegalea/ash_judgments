# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Banding do
  @moduledoc """
  The test host's banding ledger: the Banding fragment on the host's own
  base (Postgres + AshEvents audit) — the RFC §7.1 record, recorded never
  recomputed.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Banding.Fragment]

  events do
    event_log(AshJudgments.Test.EventLog)
    create_timestamp :banded_at
  end

  postgres do
    table "test_bandings"
    repo(AshJudgments.TestRepo)
  end
end

defmodule AshJudgments.Test.Certification do
  @moduledoc """
  The test host's band-table certification ledger (RFC §8.2,
  judgment-side).
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Banding.CertificationFragment]

  events do
    event_log(AshJudgments.Test.EventLog)
    create_timestamp :certified_at
  end

  postgres do
    table "test_band_table_certifications"
    repo(AshJudgments.TestRepo)
  end
end
