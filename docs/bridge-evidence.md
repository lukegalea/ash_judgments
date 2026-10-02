<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# The evidence bridge

`AshJudgments.Bridge.Evidence.artifact_attrs(observation, banding_or_nil, opts)`
spells a recorded judgment — and its banding, when one exists — as an
`AshCompliance.Resources.EvidenceArtifact` create input. **The bridge never
writes**: the host takes the map through its own domain, where its policies
apply. The mapping is pure over recorded rows: it never calls an instrument,
re-evaluates a band table, or consults ash_decisions.

## The convention

| Attribute | Value |
|---|---|
| `method` | `:examine` — the only honest member of the OSCAL method set: an instrument examined a document |
| `collector` | `"systemone:<model_digest>@<runtime_version>"` — digest-forward identity (§5.3: a model tag is never enough), version-qualified because the runtime version is part of the verdict's identity (law 6, `[L]3`) |
| `hash` | the observation's `document_version_hash` (the ledger's `document_hash`) — the content examined |
| `subject_type` / `subject_id` | the observation's SUBJECT (a vendor, a note) — never the document |
| `media_type` | `"application/json"` by default (the normalised document body); pass the document's true media type when you have it |
| `collected_at` | the observation's `recorded_at` |

A `nil` digest renders as `systemone:unknown@…` — the OSCAL export check
downstream fails such a collector, which is the honest signal that the
observation cannot name its model.

## Chain of custody

Entries in the resource's `%{at, actor, action, location}` shape, each
additionally carrying `judgment_id`, `banding_id`, `question_hash`, the
band-table content hash and `admission_id` (extra keys are free — the column
is an array of maps):

1. `%{at: recorded_at, actor: collector, action: "judged", location: zone_id}` —
   what the instrument did. Extraction observations also carry `atom_ids`:
   the source atom ids, **never quotations** (law 8).
2. When a banding is supplied:
   `%{at: banded_at, actor: admission actor, action: "admitted" | "omitted" |
   "reviewed", location: zone_id}` — what the band table decided. The actor
   is `opts[:admission_actor]`, defaulting to the collector (the band-table
   step ran under the same automation); the `admission_id` is
   `opts[:admission_id]`, nil when no admission exists yet. The band-table
   content hash is the one **recorded** on the banding — the bridge
   re-evaluates nothing.

`location` is ALWAYS the zone id (the record's `region`, law 10) — never a
host name (RFC §9 rule 2).

## Invariants and refusals

- **No artifact attribute ever carries document text** (§9 rule 1): the map
  carries hashes, ids and scalars only. Asserted in tests across every
  answer kind, banded and un-banded.
- Shadow-mode observations never map — a candidate call is not evidence
  (ArgumentError).
- An observation with no `document_version_hash` examined nothing; there is
  nothing for `method: :examine` to point at (ArgumentError, not a nil
  evidence row).

## Degradation and validation

Building the map needs no dependency. `available?/0` reports the optional
`ash_compliance` edge; `validate/1` checks a returned map's keys against the
actual `EvidenceArtifact` attribute set when the dependency is present, and
degrades to `{:error, {:missing_dependency, :ash_compliance}}` when absent —
never raises.

Required opts: `:organization_id`, `:control_id` (host-side keys the bridge
cannot infer). Optional: `:media_type`, `:retention_class`,
`:admission_actor`, `:admission_id`.

## The `[L]6` note

When `ash_evidence` eventually exists, the atom/packet mapping (ADR 0044,
RFC Q15's separate assertion record) moves THERE; only the EvidenceArtifact
convention on this module stays. Recorded per the placement decision —
nothing to build now.

## OSCAL export expectation

The OSCAL export of an artifact built by this convention stays schema-valid,
and the collector names the model (the digest). The export itself is
ash_compliance/host machinery — referenced here, not rebuilt; this package
asserts only the convention on the map.

`ash_compliance` itself changes not at all — this convention is *recorded*,
which is documentation, not a dependency edge.
