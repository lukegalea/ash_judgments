# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Ledger.Record do
  @moduledoc """
  The registry's recorder — the hand-off from a judged answer to the
  host's ledger (replacing AST-87's no-op).

  Called by the generated `judge_*` actions after upstream `evaluate`
  returns. It builds the observation's inputs — question identity from
  the registry, state digest from the canonical encoder, the model spec
  as REQUESTED (base_url and keys stripped, §9), the caller's subject and
  correlation refs, the measured latency — and invokes the host ledger's
  `:record` create. The instrument was already called; this is pure
  recording (law 2).

  The host ledger is configured, not discovered:

      config :ash_judgments, :ledger, MyApp.SystemOne.Judgment

  The question's `record:` option is the failure posture:

  - **`:must`** (compliance families) — a failed record FAILS the judge
    action: no answer is returned to the caller (fail closed, AC-2).
  - **`:best_effort`** (tooling) — the answer is returned and
    `[:ash_judgments, :record, :failed]` telemetry carries the failure
    (AC-3). The metadata carries identities and an error digest, never
    answer text or state content (§9).
  """

  @moduledoc since: "0.1.0"

  require Logger

  alias AshJudgments.Registry.Canonical

  @failed_event [:ash_judgments, :record, :failed]

  @doc """
  Records `answer` for `question` against the configured host ledger.

  `judge_context` is the judge action's plain context map
  (`context[:judgments]` carries the caller's subject, state ref,
  correlation id, mode and instrument metadata). `timing` carries the
  measured latency and the resolved state the judge sent. Returns the
  recorded judgment or the error per the question's record posture.
  """
  @spec record(AshJudgments.Registry.Question.t(), term(), map(), map(), map()) ::
          {:ok, Ash.Struct.t() | nil} | {:error, term()}
  def record(question, answer, judge_context, timing, context) do
    case Application.get_env(:ash_judgments, :ledger) do
      nil when question.record == :must ->
        {:error,
         ArgumentError.exception(
           "question #{inspect(question.name)} is record: :must but no ledger is configured " <>
             "(config :ash_judgments, :ledger) — compliance families fail closed"
         )}

      nil ->
        # Unconfigured ledger + best-effort: silence is the no-op.
        {:ok, nil}

      ledger ->
        inputs = observation_inputs(question, answer, judge_context, timing, context)

        ledger
        |> Ash.Changeset.for_create(:record, inputs,
          tenant: tenant(judge_context),
          context: context
        )
        |> Ash.create()
        |> case do
          {:ok, judgment} ->
            {:ok, judgment}

          {:error, error} ->
            question_failed(question, error)
            {:error, error}
        end
    end
  end

  ## Observation inputs — built only from what the caller and the judge
  ## already held. Nothing here calls anything.

  # The test seam over the pure input builder (the check_pin_for_test
  # precedent): the record wiring is asserted without a registry question.
  @doc false
  def observation_inputs_for_test(question, answer, judge_context, timing) do
    observation_inputs(question, answer, judge_context, timing, %{})
  end

  defp observation_inputs(question, answer, judge_context, timing, _context) do
    refs = judge_context[:judgments] || %{}
    instrument = refs[:instrument] || %{}
    key_inputs = timing[:key_inputs] || %{}
    state = timing[:state]

    %{
      id: refs[:observation_id] || Ash.UUID.generate(),
      question_id: question.question_id,
      question_hash: question.question_hash,
      question_version: question.version,
      # The explore tier's only nil: an exploratory observation carries no
      # family (the sanctioned widening); every declared question keeps
      # its calibration grouping.
      family: family(question.family),
      subject_type: subject(refs, :type),
      subject_id: subject(refs, :id),
      state_digest: Canonical.digest(Canonical.encode(state)),
      state_ref: sanitize_map(refs[:state_ref]),
      answer_kind: answer_kind(question),
      atom_ids: answer_atom_ids(question, answer, refs),
      value: answer_value(question, answer),
      probabilities: answer_probabilities(question, answer),
      confidence: answer_confidence(question, answer),
      model_spec_requested:
        model_spec_requested(timing[:model_spec] || refs[:model_spec], question),
      wire_question_hash: timing[:wire_question_hash],
      # The recorded instrument identity equals the cache key's inputs —
      # the recorded key must reproduce the lookup key exactly. The
      # host-declared version wins; the wire's runtime-reported model
      # (the capture seam) fills the absence.
      model_version: instrument[:model_version] || timing[:model_reported],
      model_digest: key_inputs[:model_digest],
      runtime_version: key_inputs[:runtime_version],
      profile: profile_name(question.profile),
      residency: residency(question, refs),
      latency_us: timing[:latency_us],
      shadow_of: timing[:shadow_of],
      mode: timing[:mode] || mode(judge_context),
      # The provenance-envelope embed (AST-9 placeholder): a host (or the
      # explore tier's run, carrying the actor's envelope-class digest)
      # parks provenance here. Never an id-bearing field by contract.
      envelope: sanitize_map(refs[:envelope]),
      correlation_id: judge_context[:correlation_id],
      valid_until: refs[:valid_until]
    }
  end

  defp subject(refs, key) when is_map(refs) do
    case refs[:subject] do
      %{^key => value} -> value
      _ -> nil
    end
  end

  defp family(nil), do: nil
  defp family(family) when is_atom(family), do: Atom.to_string(family)
  defp family(family) when is_binary(family), do: family

  # The KIND comes from the question's declared type — the authority —
  # never from the answer's runtime shape (upstream's cast may hand back
  # the struct or its plain map).
  defp answer_kind(question) do
    question.type
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_existing_atom()
  end

  defp answer_value(question, answer) do
    case answer_kind(question) do
      :noul -> nil
      kind -> get_answer_field(answer, :value) |> present(kind)
    end
  end

  defp answer_probabilities(question, answer) do
    case answer_kind(question) do
      :noul ->
        # §5.5/Q9: a noul's distribution is derived from its single
        # probability so every decision answer has the same shape. A pure
        # function of the answer — identical on replay.
        p = get_answer_field(answer, :probability)
        %{"true" => decimal_string(p), "false" => decimal_string(1 - p)}

      _kind ->
        decimal_map(get_answer_field(answer, :probabilities))
    end
  end

  # The extraction's AND the evidence's cited atoms ARE the record's
  # atoms_considered (§5.5 lists source_ids for both kinds): source ids
  # only, never quotations (law 8). Other kinds keep the caller-supplied
  # atom_ids (the evidence-work path).
  defp answer_atom_ids(question, answer, refs) do
    case answer_kind(question) do
      kind when kind in [:extraction, :evidence] ->
        get_answer_field(answer, :source_ids) || refs[:atom_ids]

      _kind ->
        refs[:atom_ids]
    end
  end

  defp answer_confidence(question, answer) do
    case answer_kind(question) do
      :noul -> nil
      _kind -> get_answer_field(answer, :confidence) |> decimal()
    end
  end

  defp get_answer_field(answer, key) when is_struct(answer), do: Map.get(answer, key)
  defp get_answer_field(answer, key) when is_map(answer), do: Map.get(answer, key)

  defp present(nil, _kind), do: nil
  defp present(value, :choice), do: to_string(value)
  defp present(value, :evidence), do: to_string(value)
  defp present(value, :score), do: decimal_string(value)

  # An extraction's cast value: binaries ride as-is (a string extraction is
  # its own collapsed value); composites store as their JSON text — the
  # §7.4 fact chain reads it back through the facts table's scalar-JSON
  # discipline.
  defp present(value, :extraction) when is_binary(value), do: value
  defp present(value, :extraction), do: Jason.encode!(value)
  defp present(value, _kind), do: to_string(value)

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: d
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)

  defp decimal_map(nil), do: nil

  defp decimal_map(probabilities) do
    Map.new(probabilities, fn {k, v} -> {to_string(k), decimal_string(v)} end)
  end

  defp decimal_string(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value)
  defp decimal_string(value) when is_binary(value), do: value

  # §9: the model spec as REQUESTED — provider and id only. Endpoints and
  # credentials never enter a record.
  defp model_spec_requested(nil, question), do: profile_name(question.profile)

  defp model_spec_requested(spec, _question) when is_binary(spec), do: spec

  defp model_spec_requested(%{provider: provider, id: id}, _question) when is_atom(provider),
    do: "#{provider}:#{id}"

  defp model_spec_requested(_other, question), do: profile_name(question.profile)

  defp profile_name(name) when is_atom(name), do: Atom.to_string(name)
  defp profile_name(name) when is_binary(name), do: name
  defp profile_name(_resolver), do: "custom"

  defp residency(question, _refs) do
    # RFC rev 4 derives residency from zones and drops the stored field;
    # the ticket's frozen field list keeps it. `in_cluster` is the only
    # posture this package knows (DEC-HOSTED: no out-of-zone instrument).
    _ = question
    :in_cluster
  end

  defp mode(judge_context), do: judge_context[:judgments][:mode] || :live

  defp tenant(judge_context), do: judge_context[:tenant]

  defp sanitize_map(nil), do: nil
  defp sanitize_map(map) when is_map(map), do: map

  ## The failure postures.

  defp question_failed(question, error) do
    error_digest =
      Canonical.digest(%{
        "class" => error.__struct__ |> Module.split() |> Enum.join("."),
        "message" => Exception.message(error)
      })

    :telemetry.execute(@failed_event, %{}, %{
      question_id: question.question_id,
      question_hash: question.question_hash,
      family: question.family,
      record: question.record,
      error_digest: error_digest,
      region: AshJudgments.Telemetry.current_region(),
      residency: AshJudgments.Telemetry.residency_for(question.profile)
    })

    if question.record == :best_effort do
      Logger.warning(
        "judgment record failed (best_effort, no answer lost): question #{question.question_id}, " <>
          "error digest #{error_digest}"
      )
    end

    :ok
  end
end
