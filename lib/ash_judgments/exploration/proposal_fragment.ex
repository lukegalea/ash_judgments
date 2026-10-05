# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Exploration.ProposalFragment do
  @moduledoc """
  The question-proposal record fragment (explore-tier design §4.5, the
  AST-87 lineage/proposal kind) — a host-instantiated record beside the
  ledger, banding and calibration stores.

  **The detector only proposes.** What crosses the recurrence threshold K
  — or one explicit person action — mints is THIS record and nothing
  else: the draft identity object plus the recurrence evidence (wire
  hashes, invocation and actor counts, the aggregated answer
  distribution, a subject-id sample), proposer = the promoting `person`,
  the detector and its version in metadata (`[L]3`). The record is inert
  data: it never edits code, never declares, never activates, never
  widens a filter. Declaration is a person writing the DSL entry at
  `version: 1`; calibration, banding and activation follow the ordinary
  lifecycle. Nothing auto-declares.

  ## Payload discipline

  The draft identity object carries the person-written instructions —
  payload class — so it is EXCLUDED from the row's `record_hash` (the
  ledger's discipline, §4.5); the digest that pins it is `question_hash`,
  the §3.2 identity digest, computed by the `:mint` change. Wire hashes
  and counts are envelope-class; the subject-id sample is the one
  design-sanctioned carry (§4.5.2) — it lives on the record, never in an
  aggregate.

  ## Immutability

  Proposals are immutable — no update action exists. Further recurrence
  accumulates in the ledger; a revised proposal is a new person action on
  a new wire hash.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    # The caller (the person-promote action) may pass a deterministic id —
    # an idempotency key for the write.
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0,
      writable?: true,
      public?: true

    create_timestamp :proposed_at

    attribute :record_version, :string,
      default: "0",
      writable?: false,
      public?: true

    attribute :record_hash, :string,
      public?: true,
      description:
        "Digest of the row's canonical JSON minus record_hash minus the identity object (§4.5 discipline — the instructions are payload class; question_hash pins them). Computed by the :mint change; identical on replay."

    attribute :question_id, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The reserved exploratory namespace id of the subject resource: judgment:v0:<Module>#judgments/exploratory."

    attribute :question_hash, :string,
      allow_nil?: false,
      writable?: false,
      public?: true,
      description:
        "The §3.2 digest of the draft identity object — the content-addressed identity of the proposed question. Derived by the :mint change, never accepted."

    attribute :identity, :map,
      allow_nil?: false,
      public?: true,
      description:
        "The draft identity object exactly as run (§3.2 shape; version 1). The instructions are payload class."

    attribute :wire_question_hash, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The recurrence key — the §3.3 digest of the question actually sent. For an undeclared question the wire question IS the question."

    attribute :wire_question_hashes, {:array, :string},
      allow_nil?: false,
      public?: true,
      description: "The wire-hash family in the evidence (usually exactly one)."

    attribute :invocation_count, :integer,
      allow_nil?: false,
      public?: true,
      description:
        "Distinct audited action invocations tenant-wide (cache hits write no row, so they do not count)."

    attribute :actor_count, :integer,
      allow_nil?: false,
      public?: true,
      description: "The distinct-actor COUNT. No actor id is ever in any aggregate artefact."

    attribute :observation_count, :integer,
      public?: true,
      description:
        "The ledger rows behind the evidence (one invocation writes one row per subject)."

    attribute :answer_distribution, :map,
      default: %{},
      public?: true,
      description:
        "The aggregated answer distribution over the collapsed value vocabulary — does the question separate at all? Counts only."

    attribute :subject_sample, {:array, :string},
      default: [],
      public?: true,
      description: "A bounded subject-id sample (§4.5.2) — on the record, never in an aggregate."

    attribute :proposer, :map,
      allow_nil?: false,
      public?: true,
      description:
        "The promoting person: %{\"kind\" => \"person\", \"id\" => ...} ([L]3 — a sanctioned search: proposer kind is the v1 draft's to make)."

    attribute :metadata, :map,
      default: %{},
      public?: true,
      description:
        "The detector and its version (the detector rides here, never in the proposer slot), the threshold K at mint time."

    attribute :region, :string, allow_nil?: false, public?: true
    attribute :tenant, :string, public?: true
  end

  identities do
    identity :unique_id, [:id]

    # The detector proposes ONCE per wire hash: further recurrence
    # accumulates on the existing proposal's evidence.
    identity :unique_wire_question_hash, [:wire_question_hash]
  end

  actions do
    create :mint do
      description """
      Mints a question proposal (§4.5). Accepts every field except the two
      derived ones — question_hash is the §3.2 digest of the identity
      object and record_hash the envelope-class digest; both are computed
      by the change from the inputs, identical on replay (law 2).
      """

      accept [
        :id,
        :question_id,
        :identity,
        :wire_question_hash,
        :wire_question_hashes,
        :invocation_count,
        :actor_count,
        :observation_count,
        :answer_distribution,
        :subject_sample,
        :proposer,
        :metadata,
        :region,
        :tenant
      ]

      change {AshJudgments.Exploration.ProposalFragment.Changes.DeriveProposal, []}
    end

    read :by_wire_hash do
      description "The proposal for a wire-question hash, or nothing."
      get? true

      argument :wire_question_hash, :string, allow_nil?: false, public?: true

      filter expr(wire_question_hash == ^arg(:wire_question_hash))
    end

    defaults [:read]
  end
end

defmodule AshJudgments.Exploration.ProposalFragment.Changes.DeriveProposal do
  @moduledoc false
  # The :mint create's derived fields — PURE functions of the inputs
  # (law 2): question_hash is the §3.2 digest of the draft identity
  # object (a malformed identity is a validation error, never a silent
  # digest of garbage), record_hash the §4.5 digest over the row's
  # envelope-class fields minus the identity object (payload class).
  use Ash.Resource.Change

  alias AshJudgments.Registry.Canonical

  @payload_keys MapSet.new([:record_hash, :identity])

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case validate_identity(changeset) do
        {:ok, identity} ->
          question_hash = Canonical.question_hash(identity)

          record_hash =
            changeset.attributes
            |> Enum.reject(fn {k, v} -> MapSet.member?(@payload_keys, k) or is_nil(v) end)
            |> Map.new(fn {k, v} -> {Atom.to_string(k), canonical_value(v)} end)
            |> Map.put("question_hash", question_hash)
            |> Canonical.digest()

          changeset
          |> Ash.Changeset.force_change_attribute(:question_hash, question_hash)
          |> Ash.Changeset.force_change_attribute(:record_hash, record_hash)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, ArgumentError.exception(message))
      end
    end)
  end

  defp validate_identity(changeset) do
    identity = Ash.Changeset.get_attribute(changeset, :identity) || %{}

    cond do
      not is_atom(identity[:answer_type]) ->
        {:error, "a proposal identity needs an answer_type module"}

      is_nil(identity[:instructions]) ->
        {:error, "a proposal identity needs the person's instructions"}

      not is_list(identity[:options]) or identity[:options] == [] ->
        {:error, "a proposal identity needs its options (the answer vocabulary)"}

      identity[:version] != 1 ->
        {:error, "a proposal identity is version 1 — declaration bumps it"}

      not (is_nil(identity[:state_contract]) or is_binary(identity[:state_contract])) ->
        {:error, "a proposal identity's state_contract is a digest or nil"}

      true ->
        {:ok, identity}
    end
  end

  defp canonical_value(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp canonical_value(v), do: v
end
