# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.Replay do
  @moduledoc """
  Rebuilds a temporal facts table's periods by replaying its recorded
  decisions, in `effective_at` order, through `AshJudgments.Facts.Materialiser`.

  Facts are derived data, so a facts table is rebuilt from what was decided,
  never translated row by row. Replaying the recorded decisions in the order
  they took effect reconstructs the same periods (the replay-equivalence
  property, `materialise(clear + replay) ≡ materialise(live)`).

  ## Where the decisions live

  When the facts resource is audited by `AshEvents`, its event log is the
  decision sequence. `decisions_from_event_log/2` reads it back:

    * a `:materialise` create carries the full fact in `data`: an `:admitted`
      decision;
    * a `:revise` update splits the period: an `:admitted` decision whose
      `data` holds only the revised fields, laid over the record's last
      payload;
    * a `:truncate` destroy ends the period: an `:omitted` decision;
    * a `:supersede` update, written by the pre-temporal fragment, ends a
      fact's currency: an `:omitted` decision.

  Each decision takes effect at the event's `as_of` (the log needs
  `record_as_of? true`), not its `occurred_at`. A back-dated admission is
  written now and takes effect earlier, and `occurred_at` is the wall clock
  at the write unless the resource declares a `recorded_at`. An event with no
  `as_of` falls back to `occurred_at`.

  Decisions that wrote nothing (`:review`, an idempotent `:unchanged`,
  `:kept_person_fact`) left no events, so they are absent from the replay as
  they are from the table.
  """

  require Ash.Query

  alias AshJudgments.Facts.Materialiser

  @typedoc "A materialiser decision, plus the instant it takes effect."
  @type decision :: %{required(:effective_at) => DateTime.t(), optional(atom()) => term()}

  @doc """
  Replays `decisions` (maps or keyword lists in the materialiser's decision
  shape, each with an `effective_at`) in `effective_at` order. Returns
  `{:ok, %{replayed: count, materialised: n, unchanged: n,
  kept_person_fact: n, superseded: n, no_fact: n, no_prior_fact: n}}`.

  Options:

    * `:resource` - the facts resource; defaults to `config :ash_judgments, :facts`.
  """
  @spec replay(Enumerable.t(), keyword()) :: {:ok, map()}
  def replay(decisions, opts \\ []) do
    resource = facts_resource(opts)

    unless Ash.Resource.Info.temporal?(resource) do
      raise ArgumentError,
            "replay requires a temporal facts resource (one that includes " <>
              "AshJudgments.Facts.TemporalFragment): replaying through the legacy " <>
              "fragment would rebuild final states, not periods"
    end

    sorted =
      decisions
      |> Enum.map(&Map.new/1)
      |> Enum.sort_by(&effective_at_instant/1, DateTime)

    tally =
      Enum.reduce(sorted, zero_tally(), fn decision, acc ->
        {:ok, verdict} = Materialiser.materialise(decision, resource: resource)
        Map.update!(acc, verdict, &(&1 + 1))
      end)

    {:ok, Map.put(tally, :replayed, length(sorted))}
  end

  @doc """
  Reads the facts resource's recorded decisions out of `event_log`, sorted by
  `effective_at` (ties in recorded order), ready for `replay/2`.

  Options:

    * `:resource` - the facts resource; defaults to `config :ash_judgments, :facts`.
    * `:authorize?` - passed to the read of the event log; defaults to `false`.
  """
  @spec decisions_from_event_log(module(), keyword()) :: {:ok, [decision()]}
  def decisions_from_event_log(event_log, opts \\ []) do
    resource = facts_resource(opts)

    # The event log's atom columns deserialize only when the resources that
    # own the atoms are loaded.
    Code.ensure_compiled(resource)

    events =
      event_log
      |> Ash.Query.filter(
        resource == ^resource and action in [:materialise, :revise, :truncate, :supersede]
      )
      |> Ash.Query.sort([:occurred_at, :id])
      |> Ash.read!(authorize?: Keyword.get(opts, :authorize?, false))

    # Fold in recorded order, carrying each record's last payload so a revise
    # (only the revised fields) or an omission (no fields) can name the
    # subject, predicate and scope it applies to. Then put the decisions in
    # the order they took effect, which differs when a write was back-dated.
    {decisions, _payloads} = Enum.map_reduce(events, %{}, &decision/2)

    {:ok,
     decisions
     |> Enum.reject(&is_nil(&1.subject))
     |> Enum.with_index()
     |> Enum.sort_by(fn {decision, index} ->
       {DateTime.to_unix(decision.effective_at, :microsecond), index}
     end)
     |> Enum.map(&elem(&1, 0))}
  end

  defp decision(event, payloads) do
    effective_at = Map.get(event, :as_of) || event.occurred_at
    prior = Map.get(payloads, event.record_id, %{})

    case {event.action_type, event.action} do
      {:create, :materialise} ->
        # `data` is the action's input, JSON round-tripped: string keys.
        payload = event.data || %{}
        {admitted(payload, effective_at), Map.put(payloads, event.record_id, payload)}

      {:update, :revise} ->
        payload = Map.merge(prior, event.data || %{})
        {admitted(payload, effective_at), Map.put(payloads, event.record_id, payload)}

      {:destroy, :truncate} ->
        {omitted(prior, effective_at), payloads}

      {:update, :supersede} ->
        {omitted(prior, effective_at), payloads}

      _other ->
        raise ArgumentError,
              "unreplayable facts event: #{inspect(event.action_type)}/#{inspect(event.action)} " <>
                "(record #{event.record_id} at #{event.occurred_at})"
    end
  end

  defp admitted(payload, effective_at) do
    %{
      result: :admitted,
      subject: payload["subject"],
      predicate: payload["predicate"],
      value: payload["value"],
      holds: payload["holds"],
      scope: payload["scope"],
      subject_state_digest: payload["subject_state_digest"],
      valid_until: parse_dt(payload["valid_until"]),
      admission_grade: grade(payload["admission_grade"]),
      admission_id: payload["admission_id"],
      effective_at: effective_at
    }
  end

  defp omitted(payload, effective_at) do
    %{
      result: :omitted,
      subject: payload["subject"],
      predicate: payload["predicate"],
      scope: payload["scope"],
      effective_at: effective_at
    }
  end

  defp facts_resource(opts) do
    opts[:resource] || Application.get_env(:ash_judgments, :facts) ||
      raise ArgumentError,
            "no facts resource configured; set config :ash_judgments, :facts or pass :resource"
  end

  # The grade contract's whole vocabulary.
  defp grade("grant"), do: :grant
  defp grade("person"), do: :person
  defp grade(nil), do: nil
  defp grade(other) when is_atom(other), do: other

  defp parse_dt(nil), do: nil
  defp parse_dt(%DateTime{} = datetime), do: datetime

  defp parse_dt(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp effective_at_instant(decision) do
    case parse_dt(decision[:effective_at] || decision["effective_at"]) do
      %DateTime{} = datetime -> datetime
      nil -> DateTime.utc_now()
    end
  end

  defp zero_tally do
    %{
      materialised: 0,
      unchanged: 0,
      kept_person_fact: 0,
      superseded: 0,
      no_fact: 0,
      no_prior_fact: 0
    }
  end
end
