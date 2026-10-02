# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Cache do
  @moduledoc """
  Live-cache, replay and shadow modes backed by the ledger — **ticket
  AST-89** (CORE-CACHE).

  The ledger doubles as the cache. The key is the RFC §4.4 computation,
  full fidelity: `digest(canonical_json({input_hash, model_digest,
  runtime_version, wire_question_hash, zone_id}))` — the *wire* question
  hash (§3.3, what was actually sent), the model digest and runtime
  version (the instrument identity), and the zone (region). Tenancy is
  deliberately not in the key: the ledger lookup is tenant-scoped, so one
  key serves one logical call (§4.4).

  | Mode | Consults the model? | Writes an observation? | Feeds facts? |
  |---|---|---|---|
  | `:live` (default) | on a cache miss | on a miss, one `mode: :live` row | via admission |
  | `:replay` | **never** | **never** (a miss is `ReplayMiss`) | via admission |
  | `:shadow` | yes (the candidate) | one `mode: :shadow` row with `shadow_of` | **never** |

  - **`:live`** — look up by key before calling, respecting the TTL from
    the registry; on a hit, the recorded answer is rebuilt and returned
    and **no observation is written** (§6.3 — the caller references the
    existing observation); on a miss, call and record as usual.
  - **`:replay`** — answer strictly from the ledger. A miss is
    `{:error, %ReplayMiss{}}`, never a call. TTL does not apply (replay
    reproduces history); a replayed answer that disagrees with the
    original is worse than no answer (ADR 0035).
  - **`:shadow`** — call the candidate instrument and record with
    `mode: :shadow` and `shadow_of` (the live row it shadows), emitting a
    `[:ash_judgments, :shadow, :diff]` event (value changed + the delta
    in p). The caller receives the live answer when a live row exists;
    shadow rows are never banded and never materialise into facts.

  Modes resolve per call (the judge context's `mode`), then per process
  (`Logger.metadata(judgments_mode: mode)`), then per config
  (`config :ash_judgments, :mode`), defaulting to `:live`.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Registry.Canonical

  defmodule ReplayMiss do
    @moduledoc """
    Replay mode found no recorded observation for this call. The error
    carries the key and the question — never a fabricated answer. A
    Splode error (class `:unknown`) so it passes through the Ash action
    boundary intact.
    """

    use Splode.Error, fields: [:cache_key, :question_id], class: :unknown

    def message(%{cache_key: cache_key, question_id: question_id}) do
      "replay miss: no recorded observation for question #{question_id} " <>
        "with cache key #{cache_key} — replay never calls the instrument"
    end
  end

  defmodule PinMismatch do
    @moduledoc """
    The runtime answered with a different model than the pinned
    expectation (law 6: a floating instrument is a silent policy change).
    Raised where the reported identity is available; per §5.7 rule 3 the
    observation may exist but may never feed admission.
    """

    use Splode.Error,
      fields: [:expected, :reported, :question_id],
      class: :forbidden

    def message(%{expected: expected, reported: reported, question_id: question_id}) do
      "pin mismatch for question #{question_id}: pinned #{inspect(expected)}, " <>
        "instrument reported #{inspect(reported)} (law 6)"
    end
  end

  @doc """
  The §4.4 cache key, full fidelity: the state's input hash, the model
  digest, the runtime version, the WIRE question hash and the zone. All
  inputs must be the values the call itself used — a key computed from
  anything else is a cache of a different call.
  """
  @spec key(%{
          required(:state_digest) => String.t(),
          required(:model_digest) => String.t() | nil,
          required(:runtime_version) => String.t() | nil,
          required(:wire_question_hash) => String.t() | nil,
          required(:zone_id) => atom() | String.t()
        }) :: String.t()
  def key(%{
        state_digest: state_digest,
        model_digest: model_digest,
        runtime_version: runtime_version,
        wire_question_hash: wire_question_hash,
        zone_id: zone_id
      }) do
    Canonical.digest(%{
      "input_hash" => state_digest,
      "model_digest" => model_digest,
      "runtime_version" => runtime_version,
      "wire_question_hash" => wire_question_hash,
      "zone_id" => to_string(zone_id)
    })
  end

  @doc """
  Live lookup: the most recent not-superseded observation with this key,
  within the TTL (seconds). `nil` when absent or expired — a miss. The
  TTL comes from the registry's per-question `ttl`; `nil` (the default)
  means never reuse.
  """
  @spec lookup_live(module(), String.t(), pos_integer() | nil) :: term() | nil
  def lookup_live(resource, cache_key, ttl_seconds) do
    case lookup_replay(resource, cache_key) do
      {:ok, record} ->
        if within_ttl?(record, ttl_seconds), do: record, else: nil

      _miss_or_error ->
        # A read failure is a miss in live mode: the call proceeds.
        nil
    end
  end

  @doc """
  Replay lookup: the recorded observation for this key, IGNORING the TTL
  (replay reproduces history — an expired row is still a hit), or
  `:miss`.
  """
  @spec lookup_replay(module(), String.t()) :: {:ok, term()} | :miss
  def lookup_replay(resource, cache_key) do
    case Ash.Query.for_read(resource, :by_cache_key, %{cache_key: cache_key}) |> Ash.read() do
      {:ok, [record | _]} -> {:ok, record}
      {:ok, []} -> :miss
      {:error, error} -> {:error, error}
    end
  end

  defp within_ttl?(_record, nil), do: false

  defp within_ttl?(record, ttl_seconds) when is_integer(ttl_seconds) do
    DateTime.diff(DateTime.utc_now(), record.recorded_at) <= ttl_seconds
  end

  @doc """
  Rebuilds the typed answer from a recorded observation, for cache hits
  and replays. The question supplies the declared type and (for a Score)
  the ordered levels the distribution indexes into.
  """
  @spec rebuild_answer(term(), AshJudgments.Registry.Question.t()) ::
          {:ok, term()} | {:error, term()}
  def rebuild_answer(record, question) do
    case answer_kind(question) do
      :noul ->
        p = parse_float(probability_of(record))
        {:ok, struct(AshAi.Evaluate.Noul, probability: p)}

      :choice ->
        {:ok,
         struct(AshAi.Evaluate.Choice,
           value: rebuild_value(record.value),
           probabilities: rebuild_probabilities(record.probabilities),
           confidence: parse_float_or_nil(record.confidence)
         )}

      :score ->
        levels = question.constraints[:levels] || []
        probabilities = rebuild_probabilities(record.probabilities)

        level =
          probabilities
          |> Enum.max_by(fn {_index, p} -> p end, fn -> {0, 0.0} end)
          |> then(fn {index, _p} -> Enum.at(levels, index) end)

        {:ok,
         struct(AshAi.Evaluate.Score,
           value: parse_float_or_nil(record.value),
           level: level,
           probabilities: probabilities,
           confidence: parse_float_or_nil(record.confidence)
         )}

      other ->
        {:error, "cannot rebuild answer of kind #{inspect(other)}"}
    end
  end

  @doc """
  The shadow diff (law 6's model-upgrade signal): whether the candidate's
  value differs from the incumbent's, and the delta in the top
  probability. Emitted as `[:ash_judgments, :shadow, :diff]`; no content
  rides the event.
  """
  @spec diff(term(), term()) :: %{value_changed: boolean(), delta_p: float() | nil}
  def diff(live_answer, shadow_answer) do
    %{
      value_changed: value_of(live_answer) != value_of(shadow_answer),
      delta_p: abs(top_p(live_answer) - top_p(shadow_answer))
    }
  end

  @doc """
  The mode for a judge call, resolved in order: explicit call option
  (the judge context's `mode`), the process's
  `Logger.metadata(judgments_mode:)`, the app config
  (`config :ash_judgments, :mode`), then `:live`.
  """
  @spec resolve_mode(keyword()) :: :live | :replay | :shadow
  def resolve_mode(context_judgments) do
    explicit = context_judgments[:mode]
    process = Logger.metadata()[:judgments_mode]
    configured = Application.get_env(:ash_judgments, :mode, :live)

    [explicit, normalize_mode(process), normalize_mode(configured), :live]
    |> Enum.find(&valid_mode?/1)
  end

  defp valid_mode?(mode), do: mode in [:live, :replay, :shadow]

  defp normalize_mode(nil), do: nil
  defp normalize_mode(:live), do: :live
  defp normalize_mode(:replay), do: :replay
  defp normalize_mode(:shadow), do: :shadow

  defp normalize_mode(raw) when is_binary(raw) do
    if raw in ["live", "replay", "shadow"], do: String.to_existing_atom(raw)
  rescue
    _ -> nil
  end

  defp normalize_mode(_), do: nil

  ## Answer helpers

  defp answer_kind(question) do
    question.type
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_existing_atom()
  end

  defp value_of(answer) when is_struct(answer), do: Map.get(answer, :value)
  defp value_of(_), do: nil

  defp top_p(answer) when is_struct(answer) do
    case Map.get(answer, :probability) do
      nil ->
        answer
        |> Map.get(:probabilities, %{})
        |> Enum.map(fn {_k, p} -> p end)
        |> Enum.max(fn -> 0.0 end)

      p ->
        p
    end
  end

  defp top_p(_), do: 0.0

  defp probability_of(record) do
    (record.probabilities || %{})["true"]
  end

  defp rebuild_value(value) when is_binary(value) do
    case String.to_existing_atom(value) do
      atom when is_atom(atom) -> atom
    end
  rescue
    ArgumentError -> value
  end

  defp rebuild_value(value), do: value

  defp rebuild_probabilities(nil), do: %{}

  defp rebuild_probabilities(probabilities) do
    Map.new(probabilities, fn {k, v} ->
      index =
        case Integer.parse(to_string(k)) do
          {i, ""} -> i
          _ -> to_string(k)
        end

      {index, parse_float(v)}
    end)
  end

  defp parse_float_or_nil(nil), do: nil
  defp parse_float_or_nil(%Decimal{} = d), do: Decimal.to_float(d)
  defp parse_float_or_nil(v) when is_float(v), do: v
  defp parse_float_or_nil(v) when is_integer(v), do: v * 1.0

  defp parse_float_or_nil(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp parse_float(v) when is_float(v), do: v

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
end
