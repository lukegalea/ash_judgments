<!--
SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>

SPDX-License-Identifier: MIT
-->

# The explore tier

Exploration — labelled ordering by observation and exploratory questions
(S1-56; ADR 0048) — has one posture, enforced structurally: **it never
decides membership**. A set expression first, ordering second; an
exploratory question is an explicit bounded act; recurrence proposes,
people declare. Nothing here banded, admitted or fact-fed without the full
promotion lifecycle.

## Labelled ordering by observation (§1)

Two phases, always. The candidate set comes from a set expression the
caller already holds (a CQL2 filter or a retrieval top-N); the ordering
spec decorates the rows a person will read:

```elixir
alias AshJudgments.Exploration.Ordering

spec =
  Ordering.resolve!(MyApp.Appointment,
    question_id: "judgment:v0:MyApp.Appointment#judgments/triage_urgency",
    selector: :urgent,
    direction: :asc
  )

records = Ordering.latest_answers(ledger, spec.question_id, tenant: tenant)

ordered_rows = Ordering.sort(rows, records, spec)
chip = Ordering.chip(records[{"appointment", id}])
```

- **The read is the ledger, not the fact table** — the latest
  `mode: :live` ANSWERED observation per `(question, subject)`, riding the
  `[L]5` partial index (a host migration; indexes are not record-shape
  changes). Shadow, calibration and eval rows are calibration surfaces,
  never person-facing orderings. At the v0 record's field set every
  recorded row is an answered observation, so live+answered reduces to
  `mode = :live`; a host carrying the §5.5 `outcome` column adds that
  conjunct on its own action.
- **Registry-resolved (§1.3)** — `question_id` must be DECLARED and
  `selector` one of the question's derived options (`options_from`/`of`/
  `levels`, abstain included; a Noul's `true`/`false`). Unrecognised ids
  or selectors are validation errors (`UnknownQuestion`,
  `UnknownSelector`), never silent skips. An exploratory question never
  orders — it decorates the ordered tier as a labelled chip.
- **No score-only orderings (§1.2)** — an ordering without a selector, or
  one naming the score itself (`"score"`, `"magnitude"`, …), is refused
  (`ScoreOnlyOrdering`): it would make ranking into existence (thesis 8).
  A Score question orders by a NAMED level.
- **Ordering is decoration, never membership** — `sort/3` reorders, it
  never filters: the result is a permutation of the candidate set. A
  missing score never removes or hides a row: nulls sort last and carry no
  meaning, in both directions. Matching is on the COLLAPSED value — the
  Choice option, the winning level (argmax over the recorded
  distribution, the cache rebuild's derivation), the Noul boolean — never
  the raw score magnitude.
- **Ordering may decorate any partition** — `in`, `out`, or `unknown`
  ("most likely first" over the unassessed is exactly the assess-priority
  input). Staleness is a membership concern (S1-53); a stale fact's
  observation may still order the reading list, the chip carrying
  provenance: profile · model@digest · p · latency.

Anything that ACTS over a set — bulk actions, notifications, process
starts — reads admitted facts at a stated minimum `admission_grade`; the
ordering is never an input to any of them.

## Exploratory questions (§4.1–§4.3)

When no declared predicate covers the term, a person may run an
exploratory question — an EXPLICIT bounded action, never a trigger, never
background, never in a read path — over the candidate set they are
currently looking at:

```elixir
AshJudgments.Exploration.Run.run(MyApp.Note, %{
  type: AshAi.Evaluate.Noul,
  instructions: "person-written instructions…"
}, subjects,
  profile: :explore_local,        # the designated exploratory profile
  actor: "person:1",
  ttl: 3600
)
```

- **Bounds (`[L]4`)** — `Exploration.default_subjects/0` (100) is the
  default bound a caller's action card applies; `Exploration.hard_cap/0`
  (500) is the hard cap. Over the cap is REFUSED (`BoundExceeded`), never
  silently truncated.
- **Identity ([L]1)** — `question_id` is the reserved, content-addressed
  namespace `judgment:v0:<Module>#judgments/exploratory` (the same §3.1
  grammar, the exploratory slot); the IDENTITY is the §3.2 hash of the
  ad-hoc object exactly as run (`Exploration.identity_hash/1`) — the
  hash, not the slot, is the question. The hash covers answer type,
  criteria, instructions, options (derived from the answer type exactly
  as the registry transformer derives a declared question's), the
  `state_contract` when a projection was picked, and `version: 1`.
- **Records (§4.2, within frozen v0)** — ordinary observations:
  `mode: :live`, the §4.4 cache key applying (wire hash included — a
  cache hit writes no observation and returns the existing row's id),
  `question_hash` = the identity digest, `wire_question_hash` = the §3.3
  digest of the question actually sent. And **`family: NULL`** — the
  sanctioned widening below.
- **The widening (errata [L]2)** — RFC §5.2 marks `family` required while
  the folded §7.4 normative 5 says exploratory observations have none;
  the fold governs. The ledger fragment's `family` is nullable and a
  validation ties null to the namespace EXACTLY (`exploratory ⇔ family
  IS NULL`) — a declared question cannot lose its calibration grouping,
  and an exploratory row cannot carry one. The migration is isolated and
  revertible.
- **Never banded, never admitted, never fact-fed** — the banding input
  builder (`Bridge.Dmn.inputs/2`) and the fact materialiser
  (`Facts.Materialiser.materialise/2`) both refuse the namespace
  (`ExploratoryRefused`), at any admission grade. Exploratory answers
  reach calibration only through person labelling (§7.3
  `basis: "labelling"`) — the promotion evaluation set's on-ramp.
- **Payload discipline** — the person-written instructions ride the WIRE
  only; the record carries the digests. The run hashes the actor
  identity (envelope-class) into the row's provenance envelope for the
  distinct-actor count; no actor id is ever persisted.
- **Instrument posture** — `record: :must` (a failed record fails the run
  closed: the recurrence evidence is the point) and `pin: :optional` (it
  can never feed admission). The profile's region guard and residency
  policy still run.

## Recurrence detection (§4.4)

Deterministic, tenant-wide, grouped by `wire_question_hash` — for an
undeclared question the wire question IS the question, so the wire hash
is the dedup key:

```elixir
AshJudgments.Exploration.Recurrence.detect(ledger, k: 3)
# => [%{wire_question_hash: "sha256:…", invocation_count: 3,
#       actor_count: 2, observation_count: 6,
#       answer_distribution: %{"true" => 6}, crossed?: true}]
```

- **The unit is the audited ACTION INVOCATION**, not the row: one run
  over N subjects writes N rows sharing one correlation id and counts
  ONE. A cache hit writes no observation, so it writes no trace here —
  it does not count.
- **Envelope-only aggregates** — distinct invocation counts and
  distinct-actor COUNTS. No actor id, no subject id, no answer value is
  ever in an aggregate; the answer distribution names only the collapsed
  value vocabulary (an extraction's text value counts under its kind —
  payload stays payload).

## Promotion (§4.5)

Crossing the threshold K (default 3) — or one explicit person action —
mints a QUESTION PROPOSAL and nothing else:

```elixir
AshJudgments.Exploration.Recurrence.promote(
  ledger,
  MyApp.SystemOne.QuestionProposal,   # the host's ProposalFragment resource
  wire_question_hash,
  identity_question,                  # the ad-hoc question exactly as run
  actor: "person:7",
  subject_resource: MyApp.Note
)
```

The proposal record (the AST-87 lineage/proposal kind, as a host
fragment) carries the draft identity object plus the recurrence evidence
— wire hashes, invocation and actor counts, the aggregated answer
distribution, a subject-id sample (the one design-sanctioned carry: on
the record, never in an aggregate) — with proposer = the promoting
`person` and the detector + its version in metadata (`[L]3`; a sanctioned
`search:` proposer kind is the v1 draft's to make). One proposal per wire
hash: the detector proposes once (`AlreadyProposed` otherwise).

**The detector only proposes.** `detect/2` is a pure read. The proposal
record is inert data — it never edits code, never declares, never
activates, never widens a filter. Declaration is a person writing the DSL
entry at `version: 1` (the `priv/judgments/lock.json` check then governs
wording drift); calibration, banding and activation follow the ordinary
lifecycle. Nothing auto-declares, and historical exploratory rows stay
exploratory — nothing retroactively becomes a fact.

## Adding it to a host

```elixir
defmodule MyApp.SystemOne.QuestionProposal do
  use Ash.Resource,
    domain: MyApp.SystemOne,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Exploration.ProposalFragment]

  postgres do
    table "system_one_question_proposals"
    repo MyApp.Repo
  end
end
```

The ledger side needs only the `[L]5` index and the family widening in
the host's own migration — the fragment's `:latest_answered`,
`:exploratory_observations` and the null-family validation ship with the
package.
