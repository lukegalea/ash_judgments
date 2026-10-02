<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# The DMN bridge and bandings

Band tables live in `ash_decisions` (ADR 0041). The bridge only
FLATTENS recorded answers into FEEL inputs and defines the banding
record + output contract; the evaluation goes through the host resolver
seam. Nothing evaluates in this package, and nothing calls a model on
the banding path.

## Flattening: inputs/2

`Bridge.Dmn.inputs/2` turns recorded answers into the FEEL-ready map —
decimal strings (§4.3), per-kind:

| Kind | FEEL inputs |
|---|---|
| Noul | `<q>__p_true`, `<q>__p_false` |
| Choice | `<q>__p_<option>` (declaration order), `<q>__value`, `<q>__confidence` |
| Score | `<q>__p_<level index>`, `<q>__position`, `<q>__level` |
| Evidence | `p_supports`/`p_contradicts`/`p_insufficient`/`p_not_applicable` (+ `p_wrong_scope`), `<q>__confidence` |
| Extraction | `<q>__value`, `<q>__status`, BOTH observation ids — NO probabilities, NO confidence (ADR 0046 point 5) |

Common envelope inputs: `<family>`, `<risk_tier>`, `<jurisdiction>`.
Missing/abstained/replay-missed answers carry an explicit
`<q>__present => "false"` marker, never an absent key.

## The band contract

Band-table outputs (§7.1, frozen): `band` ∈ `admit | review | omit`
(Q11's spelling — "unknown" is the ash_rules outcome layer, not this
one), `fact_value` (admit only), optional `reason_code`.

**`matched_rule_ids` empty is a refusal, not a result** (ADR 0041): the
host's banding step refuses BEFORE any banding row is written, and the
fragment's validations keep the contract on the record.

`Bridge.Dmn.band_table_ref/2` resolves `(family, tenant)` through the
host resolver seam (an MFA) — tenant-aware resolution of which
versioned thing runs is host-side (ADR 0041, the `Process.Resolver`
pattern). The optional `ash_decisions` dependency degrades to the
structured error behind `Availability.ensure/1`.

## The banding fragment (§7.1)

`AshJudgments.Banding.Fragment` — the host instantiates it on its own
platform base. The `:record` create accepts EVERY field as input,
including the band-table's outputs and the `ash_decisions` evaluation
id — the banding is recorded, never recomputed (law 2, RFC §6.1). The
fragment's only change enforces the band contract and computes the
record hash from those inputs (pure, replay-safe).

Bandings are immutable: no update action exists. Re-banding is a new
row; admissions reference the banding id.

## The certification fragment (§8.2, judgment-side)

`AshJudgments.Banding.CertificationFragment` records WHICH band-table
definition is certified for WHICH family, on WHICH calibration run
(ADR 0043's optimise-split rule) and what the verification found.
Activation stays ash_decisions' lifecycle; revocation is a superseding
decision recorded as `status: :revoked` — certifications are superseded,
never edited.
