<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# Judgment telemetry

Every event the package emits is named `[:ash_judgments | ...]` and
carries `region` — a total that quietly covers one region is the most
common data error (law 10). Every surface shows which rung answered:
the judge metadata carries `rung: :system_one`. **No state, no answer
text, no payload-class data ever rides in telemetry** — the sentinel
test (`test/telemetry_test.exs`, AC-2) asserts it over captured events
and the span conversion, and `span_attributes/1` passes through only
the keys it names.

`AshJudgments.Telemetry.events/0` is the registry as data; the table
below is the contract.

## The event registry

| Event | Measurements | Metadata |
|---|---|---|
| `[:ash_judgments, :judgment, :start]` | `system_time` | the judge meta (below) |
| `[:ash_judgments, :judgment, :stop]` | `duration`, `latency_us` | the judge meta + `cache_hit?`, `outcome` (`:live \| :replay \| :shadow \| :failed`) |
| `[:ash_judgments, :judgment, :exception]` | `duration`, `latency_us` | the judge meta + `kind` (the error struct's kind) |
| `[:ash_judgments, :cache, :hit]` | `latency_us` | question id/hash/family, observation id, mode, region, residency, profile, model digest/version, rung |
| `[:ash_judgments, :cache, :replay_miss]` | — | question id/hash/family, mode, region, residency |
| `[:ash_judgments, :pin, :mismatch]` | — | question id/hash, `expected` vs `reported` model, region |
| `[:ash_judgments, :shadow, :diff]` | `delta_p` | question id/hash/family, `value_changed`, `shadow_of`, mode, region, residency, rung |
| `[:ash_judgments, :record, :failed]` | — | question id/hash/family, record posture, `error_digest` (a digest — the message never rides), region, residency |
| `[:ash_judgments, :residency, :denied]` | — | **the disclosure event**: profile, residency, family, tenant, `profile_region` vs `stack_region`, `refusal` (`:region_mismatch \| :policy_denied`), region, rung. The attempt's mismatch is recorded; the endpoint is NEVER named |
| `[:ash_judgments, :ledger, :tombstoned]` | — | judgment id, region (ADR 0024 erasure: the payload went, the digests stayed) |
| `[:ash_judgments, :facts, :materialised]` | `count` | predicate, verdict, grade, region |

**The judge meta** (every `:judgment` event): `family`, `question_id`,
`question_hash`, `profile`, `residency`, `model_version`,
`model_digest`, `region`, `tenant`, `mode`, `rung`.

Residency is envelope-class (§5.3/§9): the declared class of the
question's named profile — `nil` for resolver profiles, where the host
declares it. ADR 0042 makes leaving the zone a disclosure: the guard's
refusals emit `[:ash_judgments, :residency, :denied]` at the moment of
refusal, naming the mismatch and never the endpoint.

## The model-version capture

`AshJudgments.Wire.ModelCapture` is the production default wire: it
delegates to `ReqLLM.evaluate/4` and captures the runtime-REPORTED
model (`response.model` — §5.3's `model_reported`) into the calling
process. The judge reads it into the telemetry's `model_version` and
the recorded observation's `model_version` when the host declared
none. A host's own `req_llm` override owns its wire (no capture then,
by design).

## OpenTelemetry (the shape chosen)

The events ARE the span boundary (`:start` carries `system_time`;
`:stop`/`:exception` carry `duration`). The package ships **no hard
OTel edge**: `Telemetry.attach_otel/1` attaches handler-side span
emission, converting each judge event into a span via
`span_attributes/1` (attributes mirror the metadata; `sub_processor`
calls are marked `ai.disclosure = true` — ADR 0026: the call's one
ledger row is the disclosure record, this is its one span).

- The emitter is injectable — pass a module (or map) with
  `start_span/2`, `end_span/2`, `record_exception/3` speaking your OTel
  SDK.
- The default emitter speaks the `:opentelemetry` application through
  dynamic dispatch (module atoms sourced from
  `config :ash_judgments, :otel_module`), and `attach_otel/1` degrades
  to `{:error, :opentelemetry_unavailable}` when the SDK is absent —
  telemetry-only operation, never a raise.
- `AshJudgments.Telemetry.Metrics.definitions/0` builds the `:telemetry_metrics`
  definitions (counters by family × outcome × region × residency,
  latency distributions) for LiveDashboard/Prometheus;
  `telemetry_metrics` is an optional dependency and the function
  degrades without it.

## Handlers

Attach with `:telemetry.attach/4` against `AshJudgments.Telemetry.events/0`.
The house tests show the full pattern (a capturing handler + a span
collector) in `test/telemetry_test.exs`.
