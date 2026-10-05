# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Exploration.Run do
  @moduledoc """
  The exploratory question run (explore-tier design §4.1–§4.2).

  An EXPLICIT, bounded action — never a trigger, never background, never
  in a read path — over the caller's current candidate set:

      Exploration.Run.run(Note, %{
        type: AshAi.Evaluate.Noul,
        instructions: "person-written instructions…"
      }, subjects, profile: :test_local, actor: "person:1")

  Bounds (`[L]4`): the run is over the subjects the person is looking at,
  at most `Exploration.hard_cap/0` (500) — more is REFUSED, never
  truncated; `Exploration.default_subjects/0` (100) is the default bound a
  caller's action card applies when slicing its candidate set.

  What a run writes (§4.2, within frozen v0): ordinary observations with

  - `question_id` in the reserved exploratory namespace — content-
    addressed, the identity is the hash of the ad-hoc identity object;
  - **`family: NULL`** — the §7.4-n.5 reading (the sanctioned widening);
  - `mode: :live`, the §4.4 cache key applying (the wire hash included) —
    a cache hit writes no observation and returns the existing row's id;
  - the person-written instructions ride the WIRE only; the row carries
    the digests (payload class is never persisted here).

  Exploratory rows are never banded, never admitted, never fact-fed — the
  banding input builder and the fact materialiser both refuse the
  namespace (design §4.2). They reach calibration only through person
  labelling. The instrument posture is the design's: `record: :must` (a
  failed record fails the run closed — the recurrence evidence is the
  point) and `pin: :optional` (it can never feed admission anyway).
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Cache
  alias AshJudgments.Exploration
  alias AshJudgments.Ledger
  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Wire.ModelCapture

  @answer_types [AshAi.Evaluate.Noul, AshAi.Evaluate.Choice, AshAi.Evaluate.Score]

  @doc """
  Runs the ad-hoc `question` over `subjects` — each a map with `:state`
  (what the instrument sees; the projection is the caller's to apply) and
  optional `subject_type`/`subject_id` (the type defaulting to the
  module's last segment underscored), `state_ref`, `observation_id`.

  Options:

  - `:profile` (required) — the designated exploratory profile;
  - `:actor` — the person running it; hashed (envelope-class) into the
    row's provenance envelope for the distinct-actor recurrence count —
    no actor id is ever persisted;
  - `:correlation_id` — one id shared by every row of the run; THE
    invocation identity recurrence counts (default: fresh uuid);
  - `:ttl` — cache TTL seconds for the run's lookups (default nil: never
    reuse; the §4.4 key applies whenever a ttl is set);
  - `:tenant` — the Ash multitenancy tenant for the ledger writes;
  - `:req_llm` / `:instrument` — the upstream transport override and the
    instrument metadata seam (the same contracts the judge honours).

  Returns `{:ok, results}` — one map per subject: `subject_type`,
  `subject_id`, `answer`, `observation_id`, `cache_hit?` — or
  `{:error, exception}`.
  """
  @spec run(module(), map(), [map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(subject_module, question, subjects, opts)
      when is_atom(subject_module) and is_list(subjects) and is_list(opts) do
    unless Map.get(question, :type) in @answer_types do
      raise ArgumentError,
            "an exploratory question needs a supported answer type (one of #{inspect(@answer_types)})"
    end

    # Person-written instructions are required — they are the question the
    # person is exploring with. They ride the wire only; the record
    # carries their hash inside the identity digest (payload discipline).
    _instructions = Map.fetch!(question, :instructions)
    profile = Keyword.fetch!(opts, :profile)

    with :ok <- check_bounds(subjects, opts),
         {:ok, model_spec} <- resolve_model(profile, opts) do
      execute(
        subject_module,
        question,
        Enum.take(subjects, limit(opts)),
        model_spec,
        profile,
        opts
      )
    end
  end

  defp check_bounds(subjects, opts) do
    cap = Exploration.hard_cap()
    given = length(subjects)

    cond do
      given > cap ->
        {:error, %Exploration.BoundExceeded{given: given, cap: cap}}

      (opts[:limit] || 0) > cap ->
        {:error, %Exploration.BoundExceeded{given: opts[:limit], cap: cap}}

      true ->
        :ok
    end
  end

  # The run itself never slices past the cap — the limit a caller passes
  # (their action card's default: Exploration.default_subjects/0) only
  # takes the front of an already-bounded list.
  defp limit(opts),
    do: min(opts[:limit] || Exploration.default_subjects(), Exploration.hard_cap())

  defp resolve_model(profile, opts) do
    # The exploratory family is nil — nothing to pin against admission;
    # the profile's region guard and residency policy still run (§4.1).
    case AshJudgments.Profile.model_spec(%{profile: profile, family: nil}, %{}, %{
           tenant: opts[:tenant]
         }) do
      {:ok, spec} -> {:ok, spec}
      {:error, error} -> raise error
    end
  end

  defp execute(subject_module, question, subjects, model_spec, profile, opts) do
    identity_hash = Exploration.identity_hash(question)
    wire_question = wire_question(question)
    wire_question_hash = Canonical.digest(Canonical.encode(wire_question))
    instrument = opts[:instrument] || %{}

    env = %{
      subject_module: subject_module,
      question: question,
      identity_hash: identity_hash,
      wire_question_hash: wire_question_hash,
      instrument: instrument,
      model_spec: model_spec,
      profile: profile,
      ttl: opts[:ttl],
      ledger: Ledger.resource(),
      correlation_id: opts[:correlation_id] || Ash.UUID.generate(),
      actor_digest: actor_digest(opts[:actor]),
      tenant: opts[:tenant],
      req_llm: opts[:req_llm],
      context: %{judgments: Map.new(opts[:judgments] || [])}
    }

    results = Enum.map(subjects, &subject(&1, env))

    {:ok, results}
  end

  defp subject(raw_subject, env) do
    subject_type = Map.get(raw_subject, :subject_type) || default_subject_type(env.subject_module)
    subject_id = Map.get(raw_subject, :subject_id)
    subject = Map.put(raw_subject, :subject_type, subject_type)
    state = Map.fetch!(raw_subject, :state)

    key_inputs = %{
      state_digest: Canonical.digest(Canonical.encode(state)),
      model_digest: env.instrument[:model_digest],
      runtime_version: env.instrument[:runtime_version],
      wire_question_hash: env.wire_question_hash,
      zone_id: Ledger.region!()
    }

    case env.ttl && env.ledger &&
           Cache.lookup_live(env.ledger, Ledger.cache_key(key_inputs), env.ttl) do
      nil ->
        miss(subject, subject_type, subject_id, state, key_inputs, env)

      record ->
        # A cache hit writes no observation (§6.3) — the caller references
        # the existing one, and it does not count as an invocation (§4.4).
        {:ok, answer} = Cache.rebuild_answer(record, question_map(env))

        %{
          subject_type: subject_type,
          subject_id: subject_id,
          answer: answer,
          observation_id: record.id,
          cache_hit?: true
        }
    end
  end

  defp miss(subject, subject_type, subject_id, state, key_inputs, env) do
    {latency_us, evaluate_result} =
      :timer.tc(fn -> evaluate(state, env) end)

    case evaluate_result do
      {:ok, answer} ->
        judge_context = %{
          # The correlation id rides the CONTEXT TOP LEVEL (the recorder's
          # read) — the invocation identity recurrence counts.
          correlation_id: env.correlation_id,
          judgments:
            %{
              subject: %{type: subject_type, id: subject_id},
              observation_id: Map.get(subject, :observation_id) || Ash.UUID.generate(),
              state_ref: Map.get(subject, :state_ref),
              instrument: env.instrument
            }
            |> maybe_put_actor_digest(env.actor_digest),
          tenant: env.tenant
        }

        timing = %{
          state: state,
          latency_us: latency_us,
          model_spec: env.model_spec,
          model_reported: ModelCapture.reported_model(),
          wire_question_hash: env.wire_question_hash,
          mode: :live,
          key_inputs: key_inputs
        }

        case Ledger.Record.record(question_map(env), answer, judge_context, timing, %{}) do
          {:ok, judgment} ->
            %{
              subject_type: subject_type,
              subject_id: subject_id,
              answer: answer,
              observation_id: judgment.id,
              cache_hit?: false
            }

          {:error, error} ->
            # record: :must fails the run closed (§4.1): the recurrence
            # evidence is the point; half a run is not evidence.
            raise error
        end

      {:error, error} ->
        # A cast failure at this fidelity is no row (the §5.5 outcome enum
        # is not on the v0 record) — the subject reports the failure and
        # the run continues; the person sees what failed.
        %{
          subject_type: subject_type,
          subject_id: subject_id,
          answer: nil,
          observation_id: nil,
          cache_hit?: false,
          error: error
        }
    end
  end

  defp evaluate(state, env) do
    question = env.question

    evaluate_opts =
      [
        state: state,
        questions: %{instructions: question.instructions, criteria: Map.get(question, :criteria)},
        model: env.model_spec
      ]
      |> maybe_put(:req_llm, env.req_llm)

    AshAi.Actions.Evaluate.run(
      %{action: synthetic_action(question), arguments: %{}},
      evaluate_opts,
      env.context
    )
  end

  # Upstream evaluate's call shape needs an action struct (return type and
  # constraints); the synthetic struct exists ONLY to carry the ad-hoc
  # question over the ordinary wire — nothing about it is declared,
  # nothing enters the registry. The constraints are the INITIALIZED ones
  # (Ash.Type.init) — exactly what a generated judge action carries — so
  # upstream's cast sees the same contract it would on a declared
  # question.
  defp synthetic_action(question) do
    type = Map.fetch!(question, :type)

    constraints =
      case Ash.Type.init(type, Map.get(question, :constraints) || []) do
        {:ok, initialized} ->
          initialized

        {:error, error} ->
          raise ArgumentError,
                "invalid exploratory question constraints: #{inspect(error)}"
      end

    %Ash.Resource.Actions.Action{name: :exploratory, returns: type, constraints: constraints}
  end

  # The recorder's input shape: the registry question struct's duck type.
  defp question_map(env) do
    %{
      name: :exploratory,
      question_id: Exploration.question_id(env.subject_module),
      question_hash: env.identity_hash,
      version: 1,
      family: nil,
      type: Map.fetch!(env.question, :type),
      constraints: Map.get(env.question, :constraints),
      profile: env.profile,
      record: :must,
      pin: :optional
    }
  end

  defp default_subject_type(module) when is_atom(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_actor_digest(judgments, nil), do: judgments

  defp maybe_put_actor_digest(judgments, digest),
    do: Map.put(judgments, :envelope, %{"actor_digest" => digest})

  # A digest of the actor identity — envelope-class (digests and counts
  # are envelope-class; the id itself never persists). The distinct-actor
  # recurrence count reads this; no actor id is ever in any aggregate.
  defp actor_digest(nil), do: nil

  defp actor_digest(actor),
    do: Canonical.digest(%{"actor" => actor_to_string(actor)})

  defp actor_to_string(actor) when is_binary(actor), do: actor
  defp actor_to_string(actor) when is_atom(actor), do: Atom.to_string(actor)
  defp actor_to_string(actor) when is_integer(actor), do: Integer.to_string(actor)

  defp actor_to_string(actor),
    do:
      raise(
        ArgumentError,
        "exploratory run :actor must be a string, atom or integer, got #{inspect(actor)}"
      )

  # The exact object the judge would send for this question (§3.3 —
  # before the provider's normalisation): the answer type's own
  # to_question over the person's wording and criteria.
  defp wire_question(question) do
    type = Map.fetch!(question, :type)
    criteria = Map.get(question, :criteria)
    constraints = Map.get(question, :constraints) || []

    case type.to_question(question.instructions, criteria, constraints) do
      {:ok, wire} -> wire
      _ -> %{instructions: question.instructions, criteria: criteria}
    end
  end
end
