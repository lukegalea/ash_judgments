# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.Fragment do
  @moduledoc """
  The materialised-facts fragment: the fields, calculations, actions and
  pure derived changes a host includes in its own facts resource (RFC
  §7.4; the ledger fragment's sibling — see `AshJudgments.Facts`).

  The set-evaluator contract lives on three plain attributes — `subject`
  (the composite subject term, as JSON), `predicate` (the string
  spelling; for judged predicates the question id) and `value` (a JSON
  object) — which is exactly what `AshRules.Evaluator.Set` queries, with
  the data-layer equality as a superset of its strict re-verification
  (the S1-54 encoding discipline). The RFC §7.4 columns
  (`subject_type`/`subject_id` denormalised for queries, scope,
  `subject_state_digest`, `valid_until`, `admission_grade`,
  `admission_id`, `superseded_by`) ride beside them, and the freshness
  calculations (`current?`, `expired?`, `stale?/1`) are pure
  SQL-expressible reads — staleness is a comparison, never a model call.

  ## Actions

  - **`:materialise`** — the create. Accepts every field as input; the
    only change derives `subject_type`/`subject_id` from the composite
    `subject` (pure — identical on replay, law 2). Idempotency and
    supersession live in `AshJudgments.Facts.Materialiser`, which is the
    sole intended caller.
  - **`:supersede`** — the one sanctioned update: marks a fact superseded
    (facts are superseded, never edited — ADR 0044).
  - **`:current`** — every not-superseded fact; the set evaluator's table
    read and the derived query surface's base.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Fragment, of: Ash.Resource

  require Ash.Query

  calculations do
    # "Current" means not superseded (§7.4): facts are superseded, never
    # edited.
    calculate :current?, :boolean, expr(is_nil(superseded_by))

    calculate :expired?, :boolean, expr(not is_nil(valid_until) and valid_until <= now())

    # Stale = the subject's current projection digest differs from the one
    # the fact recorded (§7.4 normative 2). The host passes each subject's
    # current digest (kept per subject+question, updated in the subject's
    # own transaction); a fact without a digest (crisp) and an unknown
    # current digest both read fresh — staleness is provable, never
    # assumed.
    calculate :stale?, :boolean, {AshJudgments.Facts.Stale, []} do
      argument :current_digest, :string, allow_nil?: true
    end

    calculate :status,
              :atom,
              expr(
                cond do
                  not is_nil(superseded_by) -> :superseded
                  not is_nil(valid_until) and valid_until <= now() -> :expired
                  true -> :live
                end
              ),
              constraints: [one_of: [:live, :superseded, :expired]]
  end

  attributes do
    # The caller (the materialiser) may pass a deterministic id — an
    # idempotency key for the write.
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0,
      writable?: true,
      public?: true

    create_timestamp :recorded_at

    # The set-evaluator contract: the composite subject term, as JSON
    # ({"type": ..., "id": ...}). Opaque to this package; the data layer's
    # equality on it narrows the set evaluator's queries and its JSON
    # encoding keeps that a superset of strict equality (the S1-54
    # encoding discipline).
    attribute :subject, :map, allow_nil?: false, public?: true

    # §7.4's denormalised columns, derived from `subject` by the
    # :materialise change (pure — identical on replay).
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

    attribute :subject_state_digest, :string,
      public?: true,
      description:
        "The digest of the state projection the question saw (§5.4); nil for crisp facts."

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

    attribute :superseded_by, :uuid,
      public?: true,
      description:
        "Set by :supersede. Current means not superseded; facts are superseded, never edited."
  end

  actions do
    create :materialise do
      description """
      Writes a fact. Accepts every field as input — the materialiser
      decided the admission BEFORE this action, and replay rebuilds the
      row from these inputs without consulting anything (law 2, RFC §6.1).
      The only change derives the denormalised subject columns.
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
    end

    update :supersede do
      description "Marks this fact superseded by another (facts are superseded, never edited)."
      accept [:superseded_by]
    end

    read :current do
      description "Every not-superseded fact — the set evaluator's table read and the derived query surface's base."

      filter expr(is_nil(superseded_by))
    end

    defaults [:read]

    read :for_subject do
      description "The facts about one subject, optionally one predicate — current facts only (the recorder's lookup)."

      argument :subject, :map, allow_nil?: false, public?: true
      argument :predicate, :string, allow_nil?: true, public?: true

      filter expr(subject == ^arg(:subject) and is_nil(superseded_by))

      prepare fn query, _ ->
        case query.arguments[:predicate] do
          nil -> query
          predicate -> Ash.Query.filter(query, expr(predicate == ^predicate))
        end
      end
    end
  end

  identities do
    # Uniqueness is NOT declared: superseded history shares (subject,
    # predicate, scope) with its replacement. Current-fact uniqueness is
    # the materialiser's discipline (single-writer trigger), and the
    # §7.4 normative-4 indexes are the host migration's job.
    identity :unique_id, [:id]
  end
end

defmodule AshJudgments.Facts.Changes.DeriveSubject do
  @moduledoc false
  # The :materialise create's only change: derive the denormalised
  # subject columns from the composite subject (pure — identical on
  # replay). The subject is JSON: {"type" => ..., "id" => ...} (atom or
  # string keys accepted at the boundary).
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      subject = Ash.Changeset.get_attribute(changeset, :subject) || %{}

      type = get_subject_key(subject, "type")
      id = get_subject_key(subject, "id")

      if type == nil or id == nil do
        Ash.Changeset.add_error(
          changeset,
          ArgumentError.exception(
            ~s(the composite subject must carry type and id, e.g. %{"type" => "MyApp.Vendor", "id" => "v-1"})
          )
        )
      else
        changeset
        |> Ash.Changeset.force_change_attribute(:subject_type, to_string(type))
        |> Ash.Changeset.force_change_attribute(:subject_id, to_string(id))
      end
    end)
  end

  defp get_subject_key(subject, key) when is_map(subject) do
    Map.get(subject, key) || Map.get(subject, String.to_existing_atom(key))
  rescue
    _ -> Map.get(subject, key)
  end
end
