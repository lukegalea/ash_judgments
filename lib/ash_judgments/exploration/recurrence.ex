# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Exploration.Recurrence do
  @moduledoc """
  Deterministic recurrence detection and the promotion path
  (explore-tier design §4.4–§4.5).

  **Search demand proposes the registry.** The detector groups exploratory
  invocations by `wire_question_hash`, tenant-wide, and counts —
  ENVELOPE-ONLY: distinct invocations (the run's correlation id; one run
  over N subjects is ONE invocation) and distinct-actor COUNTS. No actor
  id, no subject id, no answer value is ever in an aggregate; the answer
  distribution names only the question's own value vocabulary. A cache hit
  writes no observation, so it writes no trace here: it does not count.

  Crossing the threshold K (default `Exploration.threshold/0` = 3) — or
  one explicit person action — mints a QUESTION PROPOSAL on the host's
  proposal resource (`AshJudgments.Exploration.ProposalFragment`): the
  draft identity object plus the recurrence evidence, proposer = the
  promoting `person`, the detector and its version in metadata (`[L]3`).

  **The detector only proposes.** `detect/2` is a pure read; it never
  mints, never edits code, never activates, never widens a filter. Only
  `promote/5` — the person's action — writes, and what it writes is an
  inert proposal record: declaration (a person writing the DSL at
  `version: 1`), calibration, banding and activation all remain the
  ordinary person-gated lifecycle. Nothing auto-declares.
  """

  @moduledoc since: "0.1.0"

  require Ash.Query

  alias AshJudgments.Exploration
  alias AshJudgments.Ledger

  @typedoc "The envelope-only aggregate for one wire-question hash."
  @type group :: %{
          required(:wire_question_hash) => String.t(),
          required(:invocation_count) => non_neg_integer(),
          required(:actor_count) => non_neg_integer(),
          required(:observation_count) => non_neg_integer(),
          required(:answer_distribution) => %{String.t() => non_neg_integer()},
          required(:crossed?) => boolean()
        }

  @doc """
  Groups the ledger's exploratory observations by wire-question hash and
  returns the envelope-only aggregates, busiest first. Options: `:k`
  (default `Exploration.threshold/0`), `:mode` (default `:live`),
  `:tenant`.

  The result is safe to surface anywhere: counts and hashes only.
  """
  @spec detect(module(), keyword()) :: [group()]
  def detect(ledger, opts \\ []) when is_atom(ledger) and is_list(opts) do
    k = Keyword.get(opts, :k, Exploration.threshold())
    mode = Keyword.get(opts, :mode, :live)

    ledger
    |> Ash.Query.for_read(:exploratory_observations, %{mode: mode}, tenant: opts[:tenant])
    |> Ash.read!()
    |> Enum.group_by(& &1.wire_question_hash)
    |> Enum.map(fn {hash, rows} -> group(hash, rows, k) end)
    |> Enum.sort_by(&{&1.invocation_count, &1.observation_count}, :desc)
  end

  defp group(wire_question_hash, rows, k) do
    invocations = rows |> Enum.map(& &1.correlation_id) |> Enum.uniq()
    actors = rows |> Enum.map(&actor_digest/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      wire_question_hash: wire_question_hash,
      invocation_count: length(invocations),
      actor_count: length(actors),
      observation_count: length(rows),
      answer_distribution: distribution(rows),
      crossed?: length(invocations) >= k
    }
  end

  # The provenance envelope is where the run parked the actor's digest
  # (envelope-class); the aggregate keeps the COUNT only.
  defp actor_digest(row),
    do: (envelope = Map.get(row, :envelope)) && envelope["actor_digest"]

  # The answer distribution names only the row's own collapsed value
  # vocabulary — options, levels, the Noul boolean — never a payload. An
  # extraction's value is text (payload class): it counts under the kind.
  defp distribution(rows) do
    rows
    |> Enum.map(&distribution_key/1)
    |> Enum.frequencies()
  end

  defp distribution_key(row) do
    case AshJudgments.Exploration.Ordering.collapse(row) do
      nil -> to_string(row.answer_kind)
      collapsed -> normalize(collapsed)
    end
  end

  defp normalize(value) when is_boolean(value), do: Atom.to_string(value)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_binary(value), do: value
  defp normalize(value), do: to_string(value)

  @doc """
  The person-promote action: mints the question proposal for
  `wire_question_hash` on the host's proposal resource — the draft
  identity object (`identity_question`, the ad-hoc question exactly as
  run — the person wrote it) plus the recurrence evidence computed from
  the ledger, proposer = `opts[:actor]` (the promoting person, required),
  the detector and its version in metadata.

  Works at or below K: crossing K is one path to this action, an explicit
  person "promote this question" is the other — both are the person's.
  A second proposal for the same wire hash is refused
  (`AlreadyProposed`): the detector proposes once.

  Options: `:actor` (required), `:question_id` (the reserved namespace id)
  or `:subject_resource` (the module — the id is derived), `:tenant`,
  `:k`, `:sample_size` (default `Exploration.default_sample_size/0`).
  """
  @spec promote(module(), module(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def promote(ledger, proposal_resource, wire_question_hash, identity_question, opts)
      when is_atom(ledger) and is_atom(proposal_resource) and is_binary(wire_question_hash) do
    actor = Keyword.fetch!(opts, :actor)
    k = Keyword.get(opts, :k, Exploration.threshold())

    question_id =
      Keyword.get_lazy(opts, :question_id, fn ->
        Exploration.question_id(Keyword.fetch!(opts, :subject_resource))
      end)

    if already_proposed?(proposal_resource, wire_question_hash, opts[:tenant]) do
      {:error, %Exploration.AlreadyProposed{wire_question_hash: wire_question_hash}}
    else
      rows = rows_for(ledger, wire_question_hash, opts)
      evidence = group(wire_question_hash, rows, k)

      proposal_resource
      |> Ash.Changeset.for_create(
        :mint,
        %{
          question_id: question_id,
          identity: Exploration.identity(identity_question),
          wire_question_hash: wire_question_hash,
          wire_question_hashes: [wire_question_hash],
          invocation_count: evidence.invocation_count,
          actor_count: evidence.actor_count,
          observation_count: evidence.observation_count,
          answer_distribution: evidence.answer_distribution,
          subject_sample: subject_sample(rows, Keyword.get(opts, :sample_size)),
          proposer: proposer(actor),
          metadata: metadata(k),
          region: to_string(Ledger.region!()),
          tenant: opts[:tenant] && to_string(opts[:tenant])
        },
        tenant: opts[:tenant]
      )
      |> Ash.create()
      |> case do
        {:ok, proposal} -> {:ok, proposal}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp already_proposed?(proposal_resource, wire_question_hash, tenant) do
    proposal_resource
    |> Ash.Query.for_read(:by_wire_hash, %{wire_question_hash: wire_question_hash},
      tenant: tenant
    )
    |> Ash.read()
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp rows_for(ledger, wire_question_hash, opts) do
    ledger
    |> Ash.Query.for_read(:exploratory_observations, %{mode: :live}, tenant: opts[:tenant])
    |> Ash.Query.filter(wire_question_hash == ^wire_question_hash)
    |> Ash.read!()
  end

  # The subject-id sample rides the PROPOSAL RECORD (§4.5.2 — the record
  # may carry it; the aggregates never do).
  defp subject_sample(rows, size) do
    rows
    |> Enum.map(& &1.subject_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(size || Exploration.default_sample_size())
  end

  # [L]3: the promoting person is the proposer — the field is a free
  # object today; a sanctioned `search:` proposer kind is the v1 draft's
  # to make. The detector rides in metadata, never in the proposer slot.
  defp proposer(actor), do: %{"kind" => "person", "id" => person_id(actor)}

  defp person_id(actor) when is_binary(actor), do: actor
  defp person_id(actor) when is_atom(actor), do: Atom.to_string(actor)
  defp person_id(actor) when is_integer(actor), do: Integer.to_string(actor)

  defp person_id(actor),
    do:
      raise(
        ArgumentError,
        "promote :actor must be a string, atom or integer (the promoting person), " <>
          "got #{inspect(actor)}"
      )

  defp metadata(k), do: Exploration.detector_metadata(k)
end
