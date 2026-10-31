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

  # The AshJudgments.A2ui.Verdicts contract, as a host declares it.
  actions do
    read :awaiting_verdict do
      filter expr(
               band == :review and
                 not exists(
                   AshJudgments.Test.HumanVerdict,
                   judgment_id in parent(observation_ids)
                 )
             )
    end

    action :record_verdict, :map do
      argument :record_id, :uuid, allow_nil?: false
      argument :value, :string, allow_nil?: false
      argument :reason, :string

      run {AshJudgments.HumanVerdict.FromBanding,
           verdict_resource: AshJudgments.Test.HumanVerdict,
           judgment_resource: AshJudgments.Test.Judgment}
    end
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

  # The AshJudgments.A2ui.Certifications contract.
  actions do
    read :certified do
      filter expr(status == :certified)
    end
  end
end
