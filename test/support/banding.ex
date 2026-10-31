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
      prepare {AshJudgments.HumanVerdict.AwaitingVerdict,
               verdict_resource: AshJudgments.Test.HumanVerdict,
               judgment_resource: AshJudgments.Test.Judgment}

      pagination offset?: true, keyset?: true, required?: false
    end

    action :record_verdict, :map do
      argument :record_id, :uuid, allow_nil?: false
      argument :answer, :atom, allow_nil?: false, constraints: [one_of: [:yes, :no]]
      argument :why, :string

      run {AshJudgments.HumanVerdict.FromBanding,
           verdict_resource: AshJudgments.Test.HumanVerdict,
           judgment_resource: AshJudgments.Test.Judgment}
    end

    # A host whose verdict values are free text (choice questions).
    action :record_text_verdict, :map do
      argument :record_id, :uuid, allow_nil?: false
      argument :answer, :string, allow_nil?: false
      argument :why, :string

      run {AshJudgments.HumanVerdict.FromBanding,
           verdict_resource: AshJudgments.Test.HumanVerdict,
           judgment_resource: AshJudgments.Test.Judgment}
    end
  end
end

defmodule AshJudgments.Test.ReviewSource do
  @moduledoc """
  The test host's review source (AshJudgments.Banding.ReviewSource). Its
  "sealing" is a reversible test encoding standing in for the host's own
  encryption, and it opens nothing without an actor. Band tables are read
  per definition version from `config :ash_judgments, :test_band_tables`,
  which the tests fill.
  """

  @behaviour AshJudgments.Banding.ReviewSource

  @doc "The test seal: what a host's encryption would produce."
  def seal(text), do: "sealed:" <> Base.encode64(text)

  @impl true
  def open_state(observations, opts) do
    if opts[:actor] do
      Map.new(observations, fn observation ->
        {observation.id, open(observation.state_ciphertext)}
      end)
    else
      %{}
    end
  end

  @impl true
  def band_table(banding, _opts) do
    version = banding.band_table["definition_version"]

    case Application.get_env(:ash_judgments, :test_band_tables, %{}) do
      %{^version => xml} -> {:ok, xml}
      _ -> :error
    end
  end

  defp open("sealed:" <> encoded), do: Base.decode64!(encoded)
  defp open(_), do: nil
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
