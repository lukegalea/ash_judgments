<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# Instrument profiles

A profile treats a model as four separable concerns, and none of them is
allowed to hardcode a model:

| Concern | Where it lives | Rule |
|---|---|---|
| **Identity** | `model` id + `digest` (sha256 as the runtime reports it) | a tag is never enough; `pin: :required` demands the digest |
| **Runtime/transport** | a ReqLLM model spec: inline (with execution metadata) for an in-zone runtime, catalog string for a hosted one | the wire is upstream `ash_ai` + `req_llm`; this package ships no client or provider |
| **Residency class** | `residency` (`in_cluster \| sub_processor`) and `region` | guarded against the stack's region; the tenant opt-out is enforced next to the client |
| **Replacement** | host config — swappable data | the homelab models are prototype instruments; models are re-chosen at launch, so nothing model-specific lives in code |

## Declaring profiles

Profiles are host config, read and validated at every use:

```elixir
config :ash_judgments,
  region: :ca,
  profiles: [
    [
      name: :laya_local,
      model: "laya:typed-decisions",
      base_url: {:system, "OLLAYA_BASE_URL"},
      api_key: {:system, "OLLAYA_API_KEY", "local"},
      residency: :in_cluster,
      region: :ca,
      digest: {:system, "OLLAYA_LAYA_DIGEST"},
      pin: :required,
      receive_timeout: 30_000
    ]
  ]
```

Schema (`AshJudgments.Profile.schema/0` is the executable source):

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | atom | required | registry key |
| `provider` | atom | `:typesafe` | the ReqLLM provider of the wire; in-zone runtimes speak the `:typesafe` wire |
| `model` | string | required | the model id, exactly as the runtime names it |
| `base_url` | `{:system, var}` \| nil | nil | nil means a hosted spec; literals are refused |
| `api_key` | `{:system, var}` | required | **never a literal** (AC-6); a third element is the fallback value |
| `residency` | `:in_cluster \| :sub_processor` | required | which zone may run the instrument (law 10) |
| `region` | `:ca \| :us` | required | the region the profile is pinned to |
| `receive_timeout` | pos integer | `30_000` | a cold load can exceed 10s |
| `digest` | string \| `{:system, var}` | nil | required when `pin: :required` |
| `pin` | `:required \| :optional` | `:optional` | compliance paths demand the pin |

`{:system, var}` references resolve at call time, never at boot, so a
release can be repointed without a rebuild. Resolution of an unset
variable fails loud, naming the variable and the profile.

## Resolution

`AshJudgments.Profile.model_spec/3` returns the ReqLLM model spec — an
inline map (with `capabilities: %{evaluate: true}` and the provider's
execution metadata) for a local profile, the catalog string
(`"typesafe:jev-1.13.0"` shape) for a hosted one. Pass it to upstream
`evaluate/2` directly, or through `Profile.resolver/2`, which returns the
arity-2 function `evaluate` accepts and raises on a refused resolution.
req_llm (>= 1.26) resolves evaluate models either from its catalog or
from such an inline spec; an in-zone runtime is in no catalog, so its
transport (`base_url`, `api_key`, `receive_timeout`) flows as call opts
via `Profile.req_llm_opts/2`, never inside the spec:

```elixir
action :triage, AshAi.Actions.Result do
  constraints of: AshAi.Evaluate.Choice, constraints: [of: [...]]
  run {AshAi.Actions.Evaluate, model: AshJudgments.Profile.resolver(:laya_local)}
end
```

A question-shaped map — `%{profile: :laya_local, family: :coi}` —
resolves through the registry and carries the family to the policy and
the pinning rules.

Guards, in order:

1. **Pin** — `pin: :required` with a `-latest`/`-preview` id raises
   `FloatingAlias` (law 6: a floating tag is a silent policy change);
   with no digest raises `MissingPin` (a profile that cannot report a
   digest cannot feed admission, RFC S1-24 §5.3).
2. **Region** — the stack declares `config :ash_judgments, :region`; a
   profile pinned to another region is refused
   (`{:error, %RegionMismatch{}}`). An undeclared stack region refuses
   everything (`{:error, %MissingRegion{}}`): a total that quietly covers
   one region is the most common data error.
3. **Residency** — the configured `ResidencyPolicy.allow?(tenant,
   residency, family)` decides. A refusal returns
   `{:error, %ResidencyDenied{}}` and **no call is made** (AC-2). The
   package's `ResidencyPolicy.Default` allows `:in_cluster` and refuses
   `:sub_processor` for every tenant — unknown tenants never opt in by
   silence (ADR 0026: the opt-out is read next to the client, in the
   action path, never inside an Ash policy check, law 3).

`model_spec/3` is pure: it performs no I/O, so a guard failure is
structurally zero network calls.

## Two-host routing is config, not code

Which model answers from which host is a mapping in host config, not a
code path:

```elixir
config :ash_judgments,
  model_routes: %{
    "winnow:e4b" => {:system, "S1_OLLAYA_GPU_BASE_URL"},
    "laya:typed-decisions" => {:system, "OLLAYA_BASE_URL"}
  }
```

Mirroring the clinic-demo spike's resolver semantics: while a route map
is configured, **every** model must have an entry — a configured map with
no entry for the profile's model fails loud
(`{:error, %RouteMissing{}}`), and a route variable that is unset fails
loud (`{:error, %MissingEnv{}}`). A result must never lie about which
host answered. Unset the map entirely for single-host routing.

## Pinning: the digest at call time

The evaluate wire returns only a model *name*; the digest comes from the
runtime's model-listing endpoint (`/api/ps`, falling back to `/api/tags`),
per the judgment-record RFC's Q7 answer. `AshJudgments.Profile.Digest`
wraps exactly that one call — explicit timeout from the profile's
`receive_timeout`, no retries — and compares prefix-wise (runtimes may
report a short prefix of the full sha256).

- `Profile.warm/1` (or `warm!/1`) verifies pin, region and digest at
  boot, from a host `Application.start/2` task, so a wrong pin or an
  absent model is a boot failure, never a user request.
- Digests drift *after* boot surface at the ledger: every judgment row
  records what answered (CORE-LEDGER), and a pinned question whose row's
  digest differs from the profile pin emits `pin_mismatch` (CORE-CACHE).

Scope boundary: this is the only outbound HTTP call in the package. It is
a reachability-and-identity check against the runtime's listing endpoint,
not model transport — the evaluate wire stays upstream.

## The dual contract test

`mix test --only instrument_contract` exercises Noul, Choice, Score and
Judgments against each configured instrument over the real wire, through
the same profile resolution production uses
(`AshJudgments.Test.InstrumentProbe`). It records the model version that
answered and fails on a digest mismatch naming both digests (AC-4).

```bash
# local job
OLLAYA_BASE_URL=http://<host>:11435 OLLAYA_MODEL="laya:typed-decisions" \
OLLAYA_DIGEST=<expected sha256> mix test --only instrument_contract

# hosted job — opt-in; never on fork PRs; dormant under DEC-HOSTED
TYPESAFE_API_KEY=... mix test --only instrument_contract
```

No default model exists in this repository on purpose: `OLLAYA_MODEL` is
required. The suite is a wire-contract suite, not a quality gate — it
proves the plumbing casts all four answer kinds; it says nothing about
calibration, which is earned per family (law 5).
