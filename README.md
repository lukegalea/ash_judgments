# AshJudgments

**The System One judgment substrate for Ash: declared questions, a provenance-carrying
ledger, and the bridges that turn recorded judgments into declarations.**

Every probabilistic judgment in the platform — about a clause in a document, an agent's
intended tool call, a candidate in a search — is the answer to a *declared, typed
question*, produced by a *replaceable instrument*, recorded as an *observation* with full
provenance, and turned into anything authoritative only by a *deterministic declaration*
(a DMN band table, an `ash_rules` bundle, an Ash action held by an actor with a grant).
Models observe; declarations decide.

## Why

A model answer that is not recorded is a rumour. A model answer that is recorded without
its instrument, its question, its state and its band is unauditable. And a probability
that reaches a decision directly — instead of through a versioned band table that a
person owns — is policy smuggled into code.

This package exists to make the boundary between *perception* and *authority*
structural, so it holds by construction rather than by care:

- questions are **declarations** in a DSL, typed by Ash types, content-hashed — the same
  `one_of` that validates an attribute is the option list of a Choice;
- answers are **observations** in a ledger the host owns, carrying the question hash, the
  model digest and runtime version, the band-table version and the region — so any verdict
  is reconstructible from identifiers and digests, never from re-running the model;
- thresholds are **policy data** in versioned DMN band tables, earned by calibration —
  never in config, never in this package;
- authority is exercised only by **actions** held by actors with grants.

The model is the replaceable part. The record — the declared question, the ledger row,
the band table — is the durable asset.

## How it fits

Transport is upstream [`ash_ai`](https://hex.pm/packages/ash_ai) 1.1: its `evaluate`
action, its answer types (`AshAi.Evaluate.Answer` and friends), over
[`req_llm`](https://hex.pm/packages/req_llm)'s provider model. **This package builds no
HTTP client, no provider behaviour and no answer types** — upstream deliberately owns all
three, and a bespoke client is a seam we do not want to maintain.

What upstream left out is what this package adds, one namespace per ticket:

| Neighbour | Role |
|---|---|
| `ash_ai` + `req_llm` | the call: evaluate, answer types, transport (upstream) |
| **`ash_judgments`** | profiles, question registry, ledger, cache/replay/shadow, telemetry, calibration, the bridges |
| `ash_decisions` | the DMN band tables that turn a distribution into an admission |
| `ash_rules` | crisp rule evaluation over the facts the ledger admits |
| `ash_bpmn` | the process lane: judge callables as `ash:call` service tasks, the human review lane |
| `ash_compliance` | the evidence surface: model-derived artifacts with chain of custody |
| `ash_events` | record-don't-recompute: replay consumes recorded judgments, never re-runs them |

## What it looks like

The scaffold ships the module layout and the availability contract; the DSL below is the
design target of the follow-up tickets, not shipped code yet.

```elixir
# AST-87: questions are declarations on the subject resource
judgments do
  question :coverage_current do
    type Evidence
    family :coi
    version 3
    options_from Credential, :status
    pii :minimised
    record :must
  end
end
```

What works today:

- **Instrument profiles** (`AshJudgments.Profile`) — host-declared, model-agnostic
  profiles over four separable concerns: identity (model id + sha256 digest pin),
  runtime/transport (a ReqLLM model spec for upstream `evaluate`), residency class
  (`in_cluster | sub_processor`, guarded against the stack's region), and replacement
  (swappable config data). Pinning fails loud on floating aliases; the tenant opt-out is
  a host-implemented `ResidencyPolicy` enforced next to the client in the action path;
  `Profile.warm/1` verifies the pin against the runtime's model-listing endpoint at boot;
  two-host routing is a config map with fail-loud semantics.

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
        pin: :required
      ]
    ]
  ```

- **`AshJudgments.Availability`** — every optional integration (the bridges, events,
  telemetry) is gated behind `Code.ensure_loaded?/1`. A missing dependency degrades to a
  structured error that names the dep, and never crashes:

  ```elixir
  AshJudgments.Bridge.Rules.available?()
  #=> {:error, {:missing_dependency, :ash_rules}}
  ```

- **A test support app** — a real Ash domain on a real PostgreSQL (synthetic resources
  only), plus a ReqLLM fixture helper so the plumbing is testable with no model on the
  path.

## What ships

- `AshJudgments` — the package contract (see the moduledoc).
- `AshJudgments.Profile` — profiles, pinning, region guard, residency policy, warm-up,
  and the digest module (`docs/instrument-profiles.md` is the full topic).
- `AshJudgments.ResidencyPolicy` — the tenant residency behaviour and its
  deny-by-silence default.
- **The question registry DSL** (`AshJudgments.Registry`) — declared, typed,
  versioned, content-hashed questions over any resource (law 4): options drawn
  from constraints, state projections with declared shapes, generated
  `judge_<name>` actions delegating to upstream `evaluate`, compile-time
  verifiers, and the version-bump lock (`docs/question-registry.md`).
- `AshJudgments.Availability` — the optional-dependency contract above.
- Module stubs for the remaining ticket wave, each with its scope in the moduledoc:
  `Ledger` (AST-88), `Cache` (AST-89), `Telemetry` (AST-90),
  `Calibration` (AST-91), `Bridge.Dmn` (AST-92), `Bridge.Rules` (AST-93),
  `Bridge.Bpmn` (AST-94), `Bridge.Evidence` (AST-95).

## What it never does

- **It never calls a model inside checks, FEEL, rules or projectors.** A guard path reads
  the ledger; a FEEL expression sees a flattened input; a projector replays a recording.
  Nondeterminism never enters a transaction, an evaluation timeout, or a rebuild.
- **It never holds thresholds in config.** Bands are versioned DMN tables, earned by
  calibration, owned by people who do not deploy. A threshold in a config file is policy
  nobody can audit or version.
- **It never stores policy.** The package records observations and proposes band tables;
  it does not decide what is allowed. Admission is an authorized action on a host
  resource; auto-admission is a named system actor holding an explicit, revocable grant.
- It ships no HTTP client, provider behaviour or answer types — upstream `ash_ai` and
  `req_llm` own the wire.

## Installation

```elixir
def deps do
  [
    {:ash_judgments, github: "lukegalea/ash_judgments"}
  ]
end
```

The core (`ash`, `ash_ai`, `req_llm`, `spark`) comes with it. The concept bridges are
optional: add `ash_decisions`, `ash_rules`, `ash_bpmn`, `ash_compliance`, `ash_events` or
`opentelemetry_ash` and the matching bridge activates (`AshJudgments.Availability.report/0`
tells you what is active in a given VM and what each missing dep would unlock).

## Development

Any PostgreSQL works. The suite reads the usual env vars (`DB_USER`, `DB_PASSWORD`,
`DB_HOST` falling back to `PGHOST`, `PGPORT`), creates and migrates its own
`ash_judgments_test` database on the fly, and runs DB tests under the `:db` tag —
`SKIP_DB=1 mix test` excludes them for runs without a database.

On the programme's development host, the `ash_enterprise` devenv provides Postgres and
the Elixir toolchain, so the suite runs as:

```bash
cd /home/lukegalea/ash_enterprise && devenv shell -- \
  bash -c 'cd /home/lukegalea/ast-forks/ash_judgments && mix test'
```

The dual contract test runs against a reachable instrument, on demand:

```bash
OLLAYA_BASE_URL=http://<host>:11435 OLLAYA_MODEL="laya:typed-decisions" \
  mix test --only instrument_contract
```

The house pre-commit gate is `mix precommit` (compile with warnings as errors, unlock
check, format, the iron-laws judge, tests, docs validation).

## Status

**Profiles and the question registry are real; the ledger and bridges are not yet.**
The package contract, the availability contract, the profile layer (AST-86), and the
question registry DSL (AST-87: hashed identity, options from constraints, generated
judge actions, verifiers, the version-bump lock) ship; the remaining namespaces are
stubs on purpose — each names its ticket (AST-88…AST-95) and ships no feature logic
until that ticket lands.

**Reversibility (thesis 6).** Tier 3 — first-party, accepted, not on hex; confined to its
own namespace and the host resources that include its fragments. The seam is upstream:
every model call goes through `AshAi.Actions.Evaluate` with a ReqLLM model spec the
profile resolver hands it, so there is no bespoke transport to unwind. The exit: delete
the package and the host resources that read it. Facts already admitted keep their values
and lose only their provenance link; predicates that depended on future admissions fall
back to `unknown` and the human lane — how they worked before this package existed.

## Licence

MIT — see [LICENSE](LICENSES/MIT.txt). REUSE-compliant from day one: every source file
carries its SPDX header, everything else is annotated in [REUSE.toml](REUSE.toml).
