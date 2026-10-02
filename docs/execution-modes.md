<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# Execution modes

The judge actions run in one of three modes (RFC §6.3), resolved per
call, then per process (`Logger.metadata(judgments_mode: mode)`), then
per config (`config :ash_judgments, :mode`), defaulting `:live`.

| Mode | Consults the model? | Writes an observation? | Feeds facts? |
|---|---|---|---|
| `:live` (default) | on a cache miss | on a miss, one `mode: :live` row | via admission |
| `:replay` | **never** | **never** (a miss raises `ReplayMiss`) | via admission |
| `:shadow` | yes (the candidate) | one `mode: :shadow` row with `shadow_of` | **never** |

## The §4.4 cache key

`cache_key = digest(canonical_json({input_hash, model_digest,
runtime_version, wire_question_hash, zone_id}))`. The wire question hash
is the digest of the exact question object sent (§3.3), computed through
the answer type's own `to_question/3`. The model digest is what the
runtime reported when available, else the profile's pinned digest. Tenancy
is deliberately not in the key: the ledger lookup is tenant-scoped (§4.4).

## Live

A hit within the question's TTL (the registry's per-question `ttl`; nil
means never reuse) returns the recorded answer — **no observation is
written** (§6.3: the caller references the existing observation; S1-56's
recurrence design depends on this) — and `[:ash_judgments, :cache, :hit]`
fires with the observation id. A miss calls the model and records as
usual.

## Replay

Answers strictly from the ledger. A miss raises
`AshJudgments.Cache.ReplayMiss` carrying the key and question id — never
a fabricated answer. TTL does not apply: replay reproduces history, so an
expired row is still a hit. The recorded answer is rebuilt through the
question's answer type, so a replayed answer that disagrees with the
original is worse than no answer (ADR 0035) is enforceable by comparing.

## Shadow

`mode: :shadow` calls the candidate instrument (set
`context[:judgments][:candidate_profile]` to override; the question's own
profile is the self-shadow default), records the candidate's answer as a
`mode: :shadow` row with `shadow_of` — the live observation it shadows —
and emits `[:ash_judgments, :shadow, :diff]` (value changed + the delta
in p). The caller receives the live answer when a live record exists;
without one, the candidate's answer returns and the row stands alone
(`shadow_of: nil`).

**Shadow rows are calibration surfaces**: never banded, never materialised
into facts, never returned by the derived reads. The facts table and
`AshJudgments.Query` see them only if someone passes them to the
materialiser explicitly — which is refused (`mode: :shadow` is not an
admission).

## Pin mismatch (AC-5)

With `pin: :required`, a runtime-reported model that differs from the
pinned expectation fails the call with
`AshJudgments.Cache.PinMismatch` (law 6). The reported identity arrives
through the context's instrument metadata — `context[:judgments][:
instrument][:model_version]` — the same capture seam the contract tests
use. Digest-level verification against `/api/tags` is the warm-up's job
(AST-86).

## The shadow re-run task

`mix ash_judgments.shadow --family F --candidate P [--since TS] [--limit N]`
selects recorded `:live` judgments and re-runs them through the candidate.
It requires two host seams — `config :ash_judgments, :state_resolver`
(digest → state; the ledger stores digests, not content) and
`config :ash_judgments, :shadow_runner` (per-judgment re-run through the
host's judge actions) — and refuses without them: shadow evaluation over
digests alone is not possible (DEC-PRIVACY), and the task would rather
refuse than fabricate.
