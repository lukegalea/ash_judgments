# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Bridge.Evidence do
  @moduledoc """
  The evidence bridge (ticket AST-95, CORE-BRIDGE-EVIDENCE): the spelling
  of a recorded judgment — and its banding, when one exists — as an
  `AshCompliance.Resources.EvidenceArtifact` create input.

  The bridge is a **pure mapping over recorded rows**. It never writes:
  the host takes the returned map through its own domain, where its
  policies apply. It never calls an instrument, re-evaluates a band
  table, or consults ash_decisions — every field is read off the
  observation and banding records.

  ## The convention (t-core-bridge-placement §4)

  - `method: :examine` — the only honest member of the OSCAL method set:
    an instrument examined a document.
  - `collector: "systemone:<model_digest>@<runtime_version>"` —
    digest-forward identity (§5.3: a model tag is never enough),
    version-qualified because the runtime version is part of the
    verdict's identity (law 6, `[L]3`).
  - `hash:` the observation's `document_version_hash` — the content
    examined (stored as the ledger's `document_hash`). An observation
    without a document hash examined nothing; mapping it is a contract
    error (ArgumentError), not a nil evidence row.
  - `subject_type`/`subject_id` — the observation's SUBJECT (a vendor, a
    note), never the document.
  - `chain_of_custody` entries in the resource's `%{at, actor, action,
    location}` shape, each additionally carrying `judgment_id`,
    `banding_id`, `question_hash`, the band-table content hash and
    `admission_id` (extra keys are free — the column is an array of
    maps):
      - entry 1 — `%{at: recorded_at, actor: collector, action: "judged",
        location: zone_id, ...}`;
      - entry 2, when a banding is supplied — `%{at: banded_at,
        actor: admission actor (opts[:admission_actor], default the
        collector — the band-table step ran under the same automation),
        action: "admitted" | "omitted" | "reviewed", location:
        zone_id, ...}`.
  - `location` is ALWAYS the zone id (the record's `region`, law 10) —
    never a host name (RFC §9 rule 2).
  - **No artifact attribute ever carries document text** (RFC §9 rule 1,
    law 8): the map carries hashes, ids and scalars only. Extraction
    observations carry their `atom_ids` — source atom ids, never
    quotations.

  Shadow-mode observations never map: a shadow row is a candidate, not
  evidence (mapping one raises ArgumentError).

  ## Degradation and validation

  Building the map needs NO dependency — it is pure over the records.
  `available?/0` reports the optional `ash_compliance` edge, and
  `validate/1` checks a returned map's keys against the actual
  `EvidenceArtifact` attribute set when the dependency is present. When
  the dependency is absent, `validate/1` degrades to
  `{:error, {:missing_dependency, :ash_compliance}}` — never raises.

  ## The `[L]6` note

  When `ash_evidence` eventually exists, the atom/packet mapping (ADR
  0044, RFC Q15's separate assertion record) moves THERE; only the
  EvidenceArtifact convention on this module stays. Recorded per the
  placement decision — nothing to build now.

  ## OSCAL export expectation

  The OSCAL export of an artifact built by this convention stays
  schema-valid, and the collector names the model (the digest). The
  export itself is ash_compliance/host machinery — referenced here, not
  rebuilt; this package asserts only the convention on the map.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Registry.Canonical

  @collector_prefix "systemone:"
  @default_media_type "application/json"

  @doc """
  `:ok` when the `ash_compliance` integration is active, otherwise
  `{:error, {:missing_dependency, :ash_compliance}}`. Never raises.
  """
  @spec available?() :: :ok | {:error, {:missing_dependency, :ash_compliance}}
  def available? do
    AshJudgments.Availability.ensure(:ash_compliance)
  end

  @doc """
  The EvidenceArtifact create-input map for an observation and its
  banding (or `nil` — a single custody entry, judged-only).

  Required opts: `:organization_id` and `:control_id` (host-side keys
  the bridge cannot infer). Optional opts: `:media_type` (default
  `"application/json"` — the normalised document body; pass the
  document's true media type when you have it), `:retention_class`,
  `:admission_actor` (entry 2's actor; default the collector),
  `:admission_id` (the admission's id when one exists yet).

  Raises ArgumentError when the observation is a shadow row or examined
  no document — both are contract errors, not degradation.
  """
  @spec artifact_attrs(map(), map() | nil, keyword()) :: map()
  def artifact_attrs(observation, banding_or_nil, opts \\ [])

  def artifact_attrs(%{mode: :shadow}, _banding, _opts) do
    raise ArgumentError,
          "shadow observations never map to evidence — a candidate call is not evidence"
  end

  def artifact_attrs(%{document_hash: nil}, _banding, _opts) do
    raise ArgumentError,
          "the observation examined no document (document_version_hash is nil) — " <>
            "there is nothing for method :examine to point at"
  end

  def artifact_attrs(observation, nil, opts) do
    base_attrs(observation, opts, [judged_entry(observation)])
  end

  def artifact_attrs(observation, banding, opts) do
    base_attrs(observation, opts, [
      judged_entry(observation),
      banded_entry(observation, banding, opts)
    ])
  end

  @doc """
  Checks an `artifact_attrs/3` result against the actual
  `AshCompliance.Resources.EvidenceArtifact` attribute set. `:ok` when
  every key names a real attribute; `{:error, {:unknown_attrs, keys}}`
  for strays; the structured missing-dependency error when
  `ash_compliance` is not active — never raises.
  """
  @spec validate(map()) ::
          :ok
          | {:error, {:unknown_attrs, [atom()]}}
          | {:error, {:missing_dependency, :ash_compliance}}
  def validate(attrs) when is_map(attrs) do
    case available?() do
      :ok ->
        known =
          AshCompliance.Resources.EvidenceArtifact
          |> Ash.Resource.Info.attributes()
          |> MapSet.new(& &1.name)

        unknown =
          attrs |> Map.keys() |> MapSet.new() |> MapSet.difference(known) |> MapSet.to_list()

        if unknown == [], do: :ok, else: {:error, {:unknown_attrs, Enum.sort(unknown)}}

      error ->
        error
    end
  end

  ## The mapping

  defp base_attrs(observation, opts, custody) do
    base = %{
      method: :examine,
      collector: collector(observation),
      hash: observation.document_hash,
      subject_type: observation.subject_type,
      subject_id: observation.subject_id,
      media_type: Keyword.get(opts, :media_type, @default_media_type),
      collected_at: observation.recorded_at,
      organization_id: Keyword.fetch!(opts, :organization_id),
      control_id: Keyword.fetch!(opts, :control_id),
      chain_of_custody: custody
    }

    case Keyword.fetch(opts, :retention_class) do
      {:ok, retention_class} -> Map.put(base, :retention_class, retention_class)
      :error -> base
    end
  end

  # Digest-forward identity (§5.3): the content digest names the model, the
  # runtime version qualifies it (law 6). A nil digest stays literally
  # "unknown" — the OSCAL export check downstream fails such a collector,
  # which is the honest signal that this observation cannot name its model.
  defp collector(observation) do
    digest = observation.model_digest || "unknown"
    @collector_prefix <> digest <> "@" <> to_string(observation.runtime_version)
  end

  defp zone(observation), do: to_string(observation.region)

  defp judged_entry(observation) do
    entry = %{
      at: observation.recorded_at,
      actor: collector(observation),
      action: "judged",
      location: zone(observation),
      judgment_id: observation.id,
      banding_id: nil,
      question_hash: observation.question_hash,
      band_table: nil,
      admission_id: nil
    }

    # Extraction observations carry their source atom ids — ids only,
    # never quotations (law 8). Absent for the other kinds.
    case observation.atom_ids do
      ids when is_list(ids) and ids != [] -> Map.put(entry, :atom_ids, ids)
      _ -> entry
    end
  end

  defp banded_entry(observation, banding, opts) do
    %{
      at: banding.banded_at,
      actor: Keyword.get(opts, :admission_actor, collector(observation)),
      action: band_action(banding.band),
      location: zone(observation),
      judgment_id: observation.id,
      banding_id: banding.id,
      question_hash: observation.question_hash,
      band_table: band_table_hash(banding),
      admission_id: Keyword.get(opts, :admission_id)
    }
  end

  # The recorded band, in the custody vocabulary: past tense, what HAPPENED.
  defp band_action(:admit), do: "admitted"
  defp band_action(:review), do: "reviewed"
  defp band_action(:omit), do: "omitted"

  # The band-table content hash as RECORDED on the banding (the bridge
  # re-evaluates nothing); a table without one falls back to its canonical
  # digest so the custody entry always pins which table spoke.
  defp band_table_hash(banding) do
    case banding.band_table do
      %{"content_hash" => hash} when is_binary(hash) and hash != "" -> hash
      table when is_map(table) -> Canonical.digest(Dmn.band_table_canonical(table))
      _ -> nil
    end
  end
end
