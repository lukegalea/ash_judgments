# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Ledger do
  @moduledoc """
  The judgment ledger — **ticket AST-88** (CORE-LEDGER).

  A model answer that is not recorded is a rumour. The ledger records
  observations: one append-only row per question per call, hash-chained to
  the question's identity (`question_hash`/`question_id` from
  `AshJudgments.Registry.Canonical`, RFC §3) and carrying the instrument's
  identity as digests, never as endpoints or keys (§9).

  ## The package supplies fragments; the host owns the resource

  `AshJudgments.Ledger.Fragment` is a `Spark.Dsl.Fragment` supplying the
  attributes, actions and derived-field changes. The HOST includes it in a
  resource defined on the host's own platform base — so the host's audit
  (AshEvents), tenancy and ownership apply to every judgment:

      defmodule MyApp.SystemOne.Judgment do
        use Ash.Resource,
          domain: MyApp.SystemOne,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshEvents.Events],
          fragments: [AshJudgments.Ledger.Fragment]

        postgres do
          table "system_one_judgments"
          repo MyApp.Repo
        end

        events do
          event_log MyApp.SystemOne.EventLog
          create_timestamp :recorded_at
        end
      end

  This is what makes a judgment auditable at all: `AshEvents` wraps only
  create, update and destroy, so the audit rides the ledger's `:record`
  create — never a generic evaluate action.

  ## Replay safety (law 2: record, don't recompute)

  The `:record` create **accepts every field as input, including the
  answer**. Its changes compute only pure derived fields (digests, the
  cache key, `region` from stack config) — no instrument call, no clock
  read for an identity field, nothing that is not an input (RFC §6.1).
  During AshEvents replay the same inputs rebuild the same row, and no
  model is ever consulted. The instrument is called BEFORE the create —
  in the judge action — and its answer arrives as an argument.

  ## Recording from the judge

  `AshJudgments.Ledger.Record` is the registry's recorder: the
  generated `judge_*` actions hand it the answer and it invokes the host
  ledger's `:record`. Configure the host ledger with
  `config :ash_judgments, :ledger, MyApp.SystemOne.Judgment`. The
  question's `record:` option decides the failure posture — `:must` fails
  the judge action closed; `:best_effort` logs, emits
  `[:ash_judgments, :record, :failed]`, and returns the answer.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Registry.Canonical

  @region_config_key :region

  @doc """
  The stack's region (law 10): host config, never a caller input.

      config :ash_judgments, region: :ca

  Every ledger row carries it; a total that quietly covers one region is
  the most common data error.
  """
  @spec region() :: {:ok, atom()} | {:error, :missing_region}
  def region do
    case Application.get_env(:ash_judgments, @region_config_key) do
      nil -> {:error, :missing_region}
      region when is_atom(region) -> {:ok, region}
    end
  end

  @doc """
  `region/0`, raising — the boot-time config validation (CORE-LEDGER/AC-7).
  A host that has not declared its region must not record judgments at all.
  """
  @spec region!() :: atom()
  def region! do
    case region() do
      {:ok, region} ->
        region

      {:error, :missing_region} ->
        raise ArgumentError,
              "no stack region configured; set config :ash_judgments, region: :ca | :us — " <>
                "every ledger row carries its region (law 10), and a record without one must not exist"
    end
  end

  @doc """
  The §4.4 cache key, full fidelity — computed ONLY from inputs (a pure
  derived field, RFC §6.1): the state's input hash, the model digest, the
  runtime version, the WIRE question hash (§3.3 — what was actually sent)
  and the zone/region. Identical on replay; different whenever any of
  them differs.

  The model digest is what the runtime reported when available, else the
  profile's pinned digest — a pinned call keys on its pin, and a call the
  runtime answered with a different model keys differently, which is the
  pin-mismatch signal showing up in the cache too.
  """
  @spec cache_key(%{
          required(:state_digest) => String.t(),
          required(:model_digest) => String.t() | nil,
          required(:runtime_version) => String.t() | nil,
          required(:wire_question_hash) => String.t() | nil,
          required(:zone_id) => atom() | String.t()
        }) :: String.t()
  def cache_key(%{
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
  The `record_hash` (RFC §4.5): the digest of the record's own canonical
  JSON, minus `record_hash` itself and minus every payload-class field.
  A row whose payload was erased still verifies.

  Payload class (§10), excluded here: `state_ciphertext` (the reserved
  state payload) — `state_ref`, `state_digest` and everything else are
  envelope-class and included.
  """
  @spec record_hash(map()) :: String.t()
  def record_hash(attrs) when is_map(attrs) do
    payload_keys = MapSet.new([:record_hash, :state_ciphertext])

    attrs
    |> Enum.reject(fn {k, v} -> k in payload_keys or is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), canonical_value(v)} end)
    |> Canonical.digest()
  end

  defp canonical_value(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp canonical_value(v), do: v
end
