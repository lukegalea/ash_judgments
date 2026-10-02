<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# The ash_rules bridge

System One is a fact producer, never an evaluator. The bridge reads the
**materialised facts table** (`config :ash_judgments, :facts`) — not the
ledger — and emits facts plus provenance for the direct evaluator, the
set evaluator and the ash_compliance guard path. The ledger joins only
as provenance display, via `fact.admission_id`.

Direction of dependency: `ash_judgments → ash_rules` (optional, behind
`Availability.ensure/1`), never the reverse — the set evaluator stays
generic over any `subject/predicate/value` fact resource.

## Fact-schema entries

`Bridge.Rules.fact_schema_entries/1` maps judged questions to
fact-schema ENTRIES (plain data; building `AshRules.Ir.FactSchema` is
the host bundle's job, because IR predicate names are atoms and this
bridge does not manufacture atoms from runtime strings — law 10):

- `name` — the question_id string (§3.1), one namespace with crisp
  fact-schema names;
- `type` — per answer kind: `:boolean` (Noul), `:string` (Choice,
  Evidence — the option vocabulary rides `:one_of`), `:number` (Score);
- `missing: :unknown` — **escalate means omission**: an absent fact is
  unknown, never false (law 7). The materialiser enforces the write
  side (review writes nothing; omit supersedes); the schema entry
  declares the read side.

## The FactBuilder: facts_for/3

Reads the current facts for a subject across the wanted predicates and
returns:

    %{
      facts: [{subject, predicate, value}],
      provenance: %{predicate => %{status, admission_grade, admission_id,
                    subject_state_digest, fact_id, scope, value}},
      omissions: [predicate]
    }

Read-side states are honoured exactly as `AshJudgments.Query.status/4`
reads them: in scope, at or above the grade floor (Q19), fresh and
unexpired — both `:in` and `:out` yield triples; every `:unknown`
reason is an omission.

## The snapshot hash: snapshot_hash/3

Pins the EXACT inputs a rules evaluation consumed, so `Bundle.content_hash/1`
(pins the rules) plus this hash (pins the facts) together pin a finding:

- a current fact contributes `{"predicate", "subject", "scope", "value",
  "admission_grade", "admission_id", "subject_state_digest"}`;
- an absent predicate contributes the explicit omission marker
  `{"predicate" => …, "no_current_fact" => true}` — a fact appearing
  later changes the hash.

SHA-256 over canonical JSON (RFC §4.3 discipline). Probabilities are
never in it — they live on observations reached via `admission_id`.

## Value encoding ([L]1)

Facts carry SCALAR JSON first — `true`, `"urgent"`, `80` — so the set
evaluator's data-layer filter and strict `values_equal?/2` hit scalar
probes directly. `AshJudgments.Facts.ScalarJson` stores the canonical
JSON TEXT (RFC §4.3 discipline: sorted keys, decimal strings), which
makes the column's text equality EXACTLY term equality. Wrapper maps
only for genuinely composite values (extraction structs), where the
schema entry declares `:map`.

## Escalate-means-omission obligations

The materialiser (S1-53) enforces the write side; this ticket pins the
obligations as tests: `review` opens a task and materialises nothing;
`omit` supersedes so the predicate returns to `unknown` for every
consumer; the materialiser NEVER deletes stale or expired facts — those
are read-side states plus reassessment enqueue (`Query.assess/4`), and
only a superseding decision moves a fact.
