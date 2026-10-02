<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# The question registry

Law 4: every question — and every output shape — is a declaration.
Questions are declared in a `judgments` block on an Ash resource, typed by
upstream answer types, given options drawn from constraints, versioned and
content-hashed; the hash is the question's identity in the ledger. Because
the question is a declaration, the manifest, the docs, the agent tooling
and the audit pack all see the model surface like any other contract.

## The two worked examples

### The clinic notes Noul

```elixir
defmodule Clinic.Scheduling.Appointment do
  use Ash.Resource, extensions: [AshAi, AshJudgments.Registry]

  judgments do
    question :notes_follow_up do
      type AshAi.Evaluate.Noul
      instructions "Does the note describe a follow-up commitment?"
      version 1
      family :clinic_notes
      profile :laya_local
      pii :minimised
      state_projection Clinic.Projections.NoteText
      state_shape %{"text" => "string"}
    end
  end
end
```

`pii: :minimised` requires the projection (a compile-time verifier): the
model sees `%{"text" => ...}` and never the raw input. `state_shape` is
the DECLARED shape of that projection's output — its canonical JSON is
what `state_contract` hashes. A projection refactor that does not alter
the declared shape does not mint a new question; one that alters what the
model can see does (RFC §3.2, Q1's resolution).

### The triage Choice

```elixir
judgments do
  question :triage_urgency do
    type AshAi.Evaluate.Choice
    options_from {Clinic.Scheduling.Appointment, :triage_urgency}
    instructions "Which triage band does this appointment need?"
    criteria %{emergency: "Immediate attention", routine: "Can wait"}
    version 1
    family :clinic_triage
    profile :laya_local
    expose_as_tool? true
  end
end
```

`options_from` derives the Choice options from the attribute's own
constraint at compile time — the same `one_of` (or `Ash.Type.Enum`) that
validates the attribute is the option list of the question — with the
abstain option (`:insufficient` by default) appended as a first-class
answer (law 7). Renaming an enum value changes the options and therefore
the hash.

### The contract extraction

The fourth kind is the package's own `AshJudgments.Evaluate.Extraction`
(implements upstream `AshAi.Evaluate.Answer`; upstream ash_ai is
untouched). One question extracts one typed value:

```elixir
question :contract_deadline do
  type AshJudgments.Evaluate.Extraction
  instructions "Extract the deadline stated in the contract."
  version 1
  family :contract_extraction
  profile :test_local
  constraints(of: :string)
  source_enum_from {MyApp.Contract, :packet_atoms}
end
```

The answer is `%Extraction{status, value, source_ids}`:

- `status` is `:found | :not_found | :ambiguous` — **required**, and
  `value` is non-nil **iff** `found`. There is no `confidence`
  field at all, so the frozen `confidence: const null` holds by
  construction (ADR 0046 point 5).
- `value` casts through the declared `of:` type (+ inner `constraints:`)
  — a `:date`, a `match`-constrained string, an enum atom. A cast
  failure is REFUSED (`cast_failed` upstream, raw recorded), never
  repaired.
- `source_ids` are the cited atom ids — ids only, never quotations
  (law 8) — validated against the packet's enum: `source_enum_from
  {Resource, :attribute}` resolves at compile time (the `options_from`
  sibling), an explicit `constraints source_enum:` list also works, and
  a declaration with neither is refused by a verifier. The fabricated-
  citation guard is that enum (CLIN-34: 0.0 on the narrowed path).
- Composite values are allowed as ONE typed value with ONE status; a
  multi-field certificate packet is several extraction questions in one
  request, one observation row each.

**Identity ([L]2)**: the declared value schema rides `criteria` (the
frozen §3.2 hash object has no value-type slot); the question's
`options` are the status enum `["found", "not_found", "ambiguous"]`.
Zero frozen-hash change; `wire_schema_hash` covers the per-call
narrowing (`Extraction.output_schema/1` — no `confidence` key anywhere).

**Extract→verify pairs** (ADR 0044): the pipeline shares one
`envelope.correlation_id` across both calls; the verification Noul
carries `evidence_ids: ["observation:<extraction-uuid>"]` and its
`source_ids` are the extraction's cited atoms only; the banding joins
the pair through `observation_ids: [extraction_id, verification_id]`
(§7.1). No forward pointer is written on the immutable extraction row —
"find the verification for X" is a read.

**FEEL inputs** (`Bridge.Dmn.inputs/2` — key set unchanged from
AST-92): `<q>__present`, `<q>__observation_id`, `<q>__value` (JSON
text), `<q>__observation_id_verified`, `<q>__status` — where `__status`
is the EXTRACTION'S OWN status read off the answer ([L]3); the
verification rides its own question key.

## Identity

- **`question_id`** — `judgment:v0:<Module>#judgments/<name>`
  (RFC §3.1). Structural: it names the slot.
- **`question_hash`** — `sha256:` over the canonical JSON (RFC §4.3) of
  exactly the identity object: `answer_type`, `instructions`, `criteria`,
  `options` (declaration order), `state_contract`, `version` (§3.2).
  Family is outside the hash (Q3): moving a question between families is
  a governance act, not a new question. Canonical JSON sorts keys, keeps
  no whitespace, renders atoms as strings and real numbers as
  shortest-round-trip decimal strings — and never normalises string
  values, so a rewording (even whitespace-only) is a new question.

Read them with the Info functions:

```elixir
AshJudgments.Registry.questions(MyResource)
AshJudgments.Registry.question(MyResource, :triage_urgency)
AshJudgments.Registry.hash(MyResource, :triage_urgency)
```

## Generated actions

Each question generates two generic actions delegating to upstream
`AshAi.Actions.Evaluate` (the package ships no transport):

- **`judge_<name>`** — takes `input` (a map); the state on the wire is
  the projection's output, never the full input; the model comes from the
  question's `profile`, resolved in the action path (tenant opt-out,
  region guard, pin — law 3).
- **`judge_<name>_matrix`** — additionally takes `questions` (one
  runtime question per element, each with `instructions` and optional
  `criteria`) and returns one answer per element.

With `expose_as_tool? true`, an ash_ai `tool` entry is generated for the
judge action — read-only by construction — so agents can call the
question over MCP (SYNTHESIS §3's MCP exposure).

## The version-bump lock

Question wording is policy: a reworded question is a *new question*, and
`version` is what says so. Commit `priv/judgments/lock.json` (an empty
`[]` opts you in) and the compile-time verifier refuses a changed hash
under an unchanged version, naming the question and both hashes
(CORE-REGISTRY/AC-3). Regenerate after a reviewed change:

```bash
mix ash_judgments.judgments.lock
```

The file maps each `question_id` to its `hash` and `version`. Edit it and
the affected resources recompile (the transformer declares it an
`@external_resource`).

## Verifiers

| Verifier | Refuses |
|---|---|
| `VerifyPiiProjection` | `pii: :minimised` without a `state_projection` |
| `VerifyRecordPin` | `record: :must` with an explicit `pin: :optional` |
| `VerifyOptionsSubset` | explicit Choice options outside the source constraint |
| `VerifyFamily` | a question without its calibration family |
| `VerifyLock` | a changed hash under an unchanged version |

## Options reference

| Option | Type | Default | Notes |
|---|---|---|---|
| `name` | atom | required | slot name (in the id, not the hash) |
| `type` | `AshAi.Evaluate.Noul \| Choice \| Score \| AshJudgments.Evaluate.Extraction` | required | `Evidence` ships with UP-AI-EVIDENCE-TYPE |
| `instructions` | string \| structured | required | wording; in the hash as declared |
| `criteria` | map \| list | — | per-option descriptions; in the hash |
| `constraints` | keyword | `[]` | `of:` for Choice, `levels:` for Score, `of:` (required) + `source_enum:` for Extraction |
| `options_from` | `{Resource, :attribute}` | — | Choice options from the attribute's constraint |
| `source_enum_from` | `{Resource, :attribute}` | — | Extraction source_ids narrowed to the packet's atom ids (required for an Extraction, or explicit `source_enum:`) |
| `abstain_option` | atom | `:insufficient` | appended to Choice options |
| `version` | pos integer | required | monotonic per question id |
| `family` | atom | required | calibration grouping (law 5); outside the hash |
| `state_projection` | module \| MFA | — | `project(input, context) :: map` |
| `state_shape` | data | — | the declared output shape; hashed as `state_contract` |
| `pii` | `:none \| :minimised` | `:none` | `:minimised` requires the projection |
| `profile` | name \| resolver | required | the instrument (AST-86) |
| `record` | `:must \| :best_effort` | `:must` | ADR 0040 record policy |
| `ttl` | pos integer (seconds) | — | cache TTL (CORE-CACHE consumes it) |
| `pin` | `:required \| :optional` | `:required` when `record: :must` | law 6 |
| `expose_as_tool?` | boolean | `false` | generates the read-only agent tool |
