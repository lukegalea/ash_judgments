# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.EventLog do
  @moduledoc """
  The AshEvents event log for the test support app: every judgment and
  verdict write lands here, which is what makes the replay test (AC-1)
  and the audit test (AC-4) possible.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  event_log do
    clear_records_for_replay(AshJudgments.Test.ClearLedger)
    primary_key_type(Ash.Type.UUIDv7)
  end

  actions do
    read :read do
      # Replay streams the log — keyset pagination required.
      primary?(true)
      pagination(keyset?: true, required?: false)
    end
  end

  postgres do
    table "test_event_log"
    repo(AshJudgments.TestRepo)
  end
end

defmodule AshJudgments.Test.ClearLedger do
  @moduledoc false
  # Clears the event-tracked tables before a replay. Test-only; speaks to
  # the repo directly because the resources it clears are the very things
  # being replayed.
  use AshEvents.ClearRecordsForReplay

  @impl true
  def clear_records!(_opts) do
    for table <-
          ~w(test_judgments test_human_verdicts test_facts test_bandings test_band_table_certifications test_question_proposals) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table, [])
    end

    :ok
  end
end

defmodule AshJudgments.Test.Judgment do
  @moduledoc """
  The test host's judgment ledger: the fragment on the host's own base
  (Postgres + AshEvents audit), exactly the shape a real host builds —
  the package never defines the persisted resource itself.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Ledger.Fragment]

  events do
    event_log(AshJudgments.Test.EventLog)
    create_timestamp :recorded_at
  end

  postgres do
    table "test_judgments"
    repo(AshJudgments.TestRepo)
  end
end

defmodule AshJudgments.Test.HumanVerdict do
  @moduledoc """
  The test host's human-verdict ledger: the fragment on the host's own
  base, audited like every judgment.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.HumanVerdict.Fragment]

  events do
    event_log(AshJudgments.Test.EventLog)
    create_timestamp :recorded_at
  end

  postgres do
    table "test_human_verdicts"
    repo(AshJudgments.TestRepo)
  end
end

defmodule AshJudgments.Test.QuestionProposal do
  @moduledoc """
  The test host's question-proposal store: the exploration proposal
  fragment on the host's own base, audited like every judgment write.
  The home record the person-promote mint creates — inert data by
  construction: nothing declares, nothing activates.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Exploration.ProposalFragment]

  events do
    event_log(AshJudgments.Test.EventLog)
    create_timestamp :proposed_at
  end

  postgres do
    table "test_question_proposals"
    repo(AshJudgments.TestRepo)
  end
end

defmodule AshJudgments.Test.FailingLedger do
  @moduledoc """
  A ledger whose `:record` always fails — the forced-insert-failure for
  the must/best-effort posture tests (AC-2/AC-3). Same duck-type surface
  the recorder calls: a `:record` create.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: Ash.DataLayer.Simple

  # The recorder's full input surface, as attributes: the duck-type
  # contract is "a resource with a :record create accepting every
  # observation field".
  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :question_id, :string, allow_nil?: false, public?: true
    attribute :question_hash, :string, allow_nil?: false, public?: true
    attribute :question_version, :integer, allow_nil?: false, public?: true
    attribute :family, :string, allow_nil?: false, public?: true
    attribute :subject_type, :string, public?: true
    attribute :subject_id, :string, public?: true
    attribute :state_digest, :string, allow_nil?: false, public?: true
    attribute :state_ref, :map, public?: true
    attribute :answer_kind, :atom, allow_nil?: false, public?: true
    attribute :atom_ids, {:array, :string}, public?: true
    attribute :value, :string, public?: true
    attribute :probabilities, :map, public?: true
    attribute :confidence, :decimal, public?: true
    attribute :model_spec_requested, :string, allow_nil?: false, public?: true
    attribute :model_version, :string, public?: true
    attribute :model_digest, :string, public?: true
    attribute :runtime_version, :string, public?: true
    attribute :profile, :string, allow_nil?: false, public?: true
    attribute :residency, :atom, public?: true
    attribute :latency_us, :integer, public?: true
    attribute :mode, :atom, public?: true
    attribute :correlation_id, :uuid, public?: true
    attribute :valid_until, :utc_datetime_usec, public?: true
    attribute :cache_key, :string, public?: true
    attribute :record_hash, :string, public?: true
    attribute :wire_question_hash, :string, public?: true
    attribute :shadow_of, :uuid, public?: true

    # Public here (the real fragment keeps it private with an explicit
    # accept): this fake's `accept [:*]` is the duck-type contract — the
    # recorder's FULL input surface must cast.
    attribute :envelope, :map, public?: true
  end

  actions do
    create :record do
      accept [:*]
      manual AshJudgments.Test.FailingLedger.AlwaysFails
    end

    read :by_cache_key do
      get?(true)

      argument(:cache_key, :string, allow_nil?: false, public?: true)
      filter(expr(cache_key == ^arg(:cache_key)))
    end
  end
end

defmodule AshJudgments.Test.FailingLedger.AlwaysFails do
  @moduledoc false
  use Ash.Resource.ManualCreate

  @impl true
  def create(_changeset, _opts, _context) do
    {:error, ArgumentError.exception("forced ledger failure (test sentinel)")}
  end
end

defmodule AshJudgments.Test.CountingLedger do
  @moduledoc """
  The observation-ledger read counter (the Phase 4 C1 test double): every
  read attempt through it increments a `:persistent_term` counter, so a
  test can prove the materialiser's absent-reference path never touches
  the ledger. `Ash.DataLayer.Simple` with no seed data: any read counts —
  and finds nothing.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: Ash.DataLayer.Simple

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :state_digest, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  preparations do
    prepare {__MODULE__.CountRead, []}
  end

  @doc "Read attempts counted since the last reset."
  def read_count do
    :persistent_term.get({__MODULE__, :reads}, 0)
  end

  @doc "Zeroes the read counter."
  def reset_read_count do
    :persistent_term.put({__MODULE__, :reads}, 0)
  end
end

defmodule AshJudgments.Test.CountingLedger.CountRead do
  @moduledoc false
  # Counts one read attempt. `:persistent_term` — node-global, so the
  # count survives Ash's internal process spawns; the tests using it run
  # `async: false`.
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    key = {AshJudgments.Test.CountingLedger, :reads}
    :persistent_term.put(key, :persistent_term.get(key, 0) + 1)
    query
  end
end
