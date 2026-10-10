# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.TemporalFragment do
  @moduledoc """
  The temporal materialised-facts fragment (AST-147; the facts
  temporal-swap design note §2): `Facts.Fragment`'s fields and contract
  with the *validity bookkeeping* moved into a period, and supersession
  bookkeeping deleted.

  ## The two time axes (the load-bearing correction)

  The period (`valid_at`) is **record validity** — which assertion is
  current. `valid_until` is **domain validity** — a licence expires on a
  date, declared per predicate. They are different axes: if expiry closed
  the period, an expired fact would read as "no row at now" —
  indistinguishable from never-assessed or omitted — destroying the
  unknown-reason classes `Query.status/4` and `assess/3` select by. So
  **expiry stays an attribute; supersession becomes the period**.

  ## What changes vs `Facts.Fragment`

  - `superseded_by` and the `:supersede` update are gone: a revision is a
    period **split** at the admission's `effective_at` (the materialiser's
    `:revise`), and an omission is a period **truncate** (`:revise`'s
    destroy sibling — history preserved, predicate returns to unknown).
  - `current?` and the `:current` filter are gone: with `strategy
    :context`, a plain read IS the as-of-now read — exactly the current
    versions, derived rather than filtered.
  - Uniqueness becomes enforced: `WITHOUT OVERLAPS` on
    `(subject_type, subject_id, predicate, scope_hash)` — one open period
    per (subject, predicate, scope) at any instant. `scope` is a map and
    cannot key an exclusion constraint, so `scope_hash` (canonical-JSON
    digest, pure, replay-identical — the `DeriveSubject` discipline) joins
    the identity.

  ## What survives verbatim

  The set-evaluator contract (`subject`/`predicate`/`value`), `holds`,
  `subject_state_digest`, `valid_until` + `expired?`, `stale?/1`, the
  grade machinery and provenance — and every §7.2 normative: admission
  policy (human-wins, omission-supersedes, review-writes-nothing,
  idempotency, the exploratory refusal) stays in
  `AshJudgments.Facts.Materialiser`, which remains the sole writer.
  **Temporal = how rows version; the materialiser = why rows change.**
  """

  @moduledoc since: "0.2.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  require Ash.Query

  temporal do
    strategy :context
    attribute :valid_at
  end

  calculations do
    calculate :expired?, :boolean, expr(not is_nil(valid_until) and valid_until <= now())

    # Stale = the subject's current projection digest differs from the one
    # the fact recorded (§7.4 normative 2) — unchanged from the legacy
    # fragment; staleness is provable, never assumed.
    calculate :stale?, :boolean, {AshJudgments.Facts.Stale, []} do
      argument :current_digest, :string, allow_nil?: true
    end

    # The consumer vocabulary keeps `:superseded` ("not current"), but an
    # as-of read only ever returns the version CURRENT at that instant, so
    # the arm is retained for wire compatibility and never returned: what
    # the legacy fragment derived from `superseded_by` is now expressed by
    # the read itself (a superseded version is simply not in an as-of
    # result).
    calculate :status,
              :atom,
              expr(
                if not is_nil(valid_until) and valid_until <= now() do
                  :expired
                else
                  :live
                end
              ),
              constraints: [one_of: [:live, :superseded, :expired]]
  end

  attributes do
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0,
      writable?: true,
      public?: true

    create_timestamp :recorded_at

    attribute :subject, :map, allow_nil?: false, public?: true

    attribute :subject_type, :string, allow_nil?: false, writable?: true, public?: true
    attribute :subject_id, :string, allow_nil?: false, writable?: true, public?: true

    attribute :predicate, :string,
      allow_nil?: false,
      public?: true,
      description:
        "One namespace: the judged question's question_id (§3.1), or the crisp fact-schema name."

    attribute :value, AshJudgments.Facts.ScalarJson,
      allow_nil?: false,
      public?: true,
      description:
        "The fact's value as JSON in the predicate's declared type (RFC §7.4): SCALARS stored as scalar JSON (true, \"urgent\", 80) so the set evaluator's data-layer filter and strict values_equal? re-verification hit directly ([L]1); wrapper maps only for genuinely composite values (extraction structs). The type accepts any JSON-encodable term; the data layer's equality remains a superset of strict equality."

    attribute :holds, :boolean,
      allow_nil?: false,
      public?: true,
      description:
        "The membership reading of the value, fixed at materialisation: true = holds (in), false = does not hold (out)."

    attribute :scope, :map,
      public?: true,
      description:
        "The context the fact holds in (e.g. %{\"tenant_id\" => ..., \"requirement_set\" => ...}); nil = the subject alone."

    # The canonical-JSON digest of `scope` — pure, replay-identical (the
    # DeriveSubject discipline). `scope` is a map and cannot key the
    # WITHOUT OVERLAPS identity; this digest is what keys it.
    attribute :scope_hash, :string, allow_nil?: false, public?: true

    attribute :subject_state_digest, :string,
      public?: true,
      description:
        "The digest of the state projection the question saw (§5.4); nil for crisp facts."

    # The SECOND time axis: domain validity (a licence expires on a date).
    # Deliberately NOT the period — an expired fact must still read as a
    # row (status :expired), never as an absence.
    attribute :valid_until, :utc_datetime_usec, public?: true

    attribute :admission_grade, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:grant, :person]],
      description:
        "Who admitted it (§7.2 actor_kind): a grant-carrying automation principal or a person (Q19)."

    attribute :admission_id, :uuid,
      public?: true,
      description:
        "Provenance back-reference (judged facts); the admission or direct-entry that wrote it."
  end

  actions do
    create :materialise do
      description """
      Opens the FIRST period of a fact. Accepts every field as input; the
      changes derive the denormalised subject columns and `scope_hash`
      (pure — identical on replay, law 2). `as_of` carries the admission's
      `effective_at`; the decision to create (vs revise) belongs to the
      materialiser, which read the version valid at that instant first.
      """

      accept [
        :id,
        :subject,
        :predicate,
        :value,
        :holds,
        :scope,
        :subject_state_digest,
        :valid_until,
        :admission_grade,
        :admission_id
      ]

      change {AshJudgments.Facts.Changes.DeriveSubject, []}
      change {AshJudgments.Facts.Changes.DeriveScopeHash, []}
    end

    destroy :truncate do
      description """
      Ends the fact's validity at the write's as_of (the omission path):
      the version current at that instant is truncated there — history is
      preserved and the predicate returns to unknown. A destroy on a
      temporal resource is a period truncate, not a row delete.
      """
    end

    update :revise do
      description """
      Revises the fact: on a temporal resource this SPLITS the version
      valid at the write's `as_of` — the superseded values keep their
      period, the revision takes over from there. This one action replaces
      the legacy supersede-then-create dance (facts are never edited; a
      revision is a new period, which is how "facts are superseded, never
      edited" is enforced by the database rather than by convention).
      """

      accept([
        :value,
        :holds,
        :subject_state_digest,
        :valid_until,
        :admission_grade,
        :admission_id
      ])
    end

    read :current do
      description """
      Every fact current NOW (the set evaluator's table read). With the
      context strategy a plain read is already the as-of-now read — this
      action exists to keep the legacy fragment's surface: callers that
      named `:current` keep working, deriving rather than filtering.
      """

      prepare build(load: [:expired?, :status])
    end

    defaults [:read]

    read :for_subject do
      description """
      The facts about one subject, optionally one predicate — as of now
      (the recorder's lookup). On a temporal resource this is an as-of
      read like every other: the versions returned are the ones valid at
      the read's `as_of` (now by default), so superseded history is absent
      by containment, not by a filter.
      """

      argument :subject, :map, allow_nil?: false, public?: true
      argument :predicate, :string, allow_nil?: true, public?: true

      filter expr(subject == ^arg(:subject))

      # Temporal safety (declared): loads the derived status fields and
      # narrows by predicate — pure query work, no clock reads, no side
      # effects; `as_of` threads through the query untouched.
      prepare {AshJudgments.Facts.Preparations.ForSubject, []}
    end
  end

  identities do
    # WITHOUT OVERLAPS (emitted as a GiST exclusion by the migration
    # generator on PG18): one open period per (subject, predicate, scope)
    # at any instant — superseded history shares the key across
    # non-overlapping periods, which is exactly the history the swap
    # preserves. `scope_hash` stands in for the map `scope`, which cannot
    # key an exclusion constraint.
    identity :unique_subject_predicate_scope, [
      :subject_type,
      :subject_id,
      :predicate,
      :scope_hash
    ]

    identity :unique_id, [:id]
  end
end

defmodule AshJudgments.Facts.Changes.DeriveScopeHash do
  @moduledoc false
  # Derives `scope_hash` from `scope`: the canonical-JSON digest (sorted
  # keys, recursive), pure and replay-identical — the DeriveSubject
  # discipline (law 2). nil scope hashes to the digest of an empty object
  # so "no scope" keys the identity deterministically.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      scope = Ash.Changeset.get_attribute(changeset, :scope) || %{}

      Ash.Changeset.force_change_attribute(
        changeset,
        :scope_hash,
        canonical_digest(scope)
      )
    end)
  end

  # Canonical JSON: objects with sorted keys, recursively; lists in order;
  # atoms stringified at the boundary (JSON round-trip makes them strings
  # on replay too — the digest is over the JSON shape, so a replayed
  # string-keyed scope digests identically).
  defp canonical_digest(term) do
    :crypto.hash(:sha256, canonical_json(term)) |> Base.encode16(case: :lower)
  end

  defp canonical_json(%{} = map) when not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {canonical_key(k), canonical_json(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(",", fn {k, v} -> ~s(#{inspect(k)}:#{v}) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(v) when is_atom(v) and not is_boolean(v), do: ~s("#{Atom.to_string(v)}")
  defp canonical_json(v) when is_binary(v), do: ~s("#{v}")
  defp canonical_json(v), do: to_string(v)

  defp canonical_key(k) when is_atom(k), do: Atom.to_string(k)
  defp canonical_key(k) when is_binary(k), do: k
  defp canonical_key(k), do: to_string(k)
end

defmodule AshJudgments.Facts.Preparations.ForSubject do
  @moduledoc false
  # The :for_subject read's preparation: loads the derived status fields
  # and narrows by the optional predicate. Temporal safety (declared):
  # pure query work — no clock reads, no side effects; `as_of` threads
  # through the query untouched.
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query =
      case query.arguments[:predicate] do
        nil -> query
        predicate -> Ash.Query.filter(query, expr(predicate == ^predicate))
      end

    Ash.Query.load(query, [:status, :expired?, :stale?])
  end

  @impl true
  def temporal_safe?(_opts), do: true
end
