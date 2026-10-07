defmodule AshEvents.TestRepo.Migrations.AddTemporalFragment do
  @moduledoc """
  Converts the test host's facts fixture table to the temporal shape
  (AST-147): `valid_at tstzrange` (the record-validity period — the
  domain-validity `valid_until` stays an attribute), `scope_hash` (the
  canonical-JSON digest that keys the WITHOUT OVERLAPS identity, since the
  map `scope` cannot), `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`, and
  the `(subject_type, subject_id, predicate, scope_hash)` GiST exclusion
  (one open period per subject+predicate+scope at any instant).
  `superseded_by` is removed: supersession IS the period now.

  The table is a test fixture (rows are disposable — the swap is not
  row-preservable by design: supersession instants are unrecoverable from
  the legacy shape, which is exactly why the migration path is
  admission-replay, not translation — design note §5.2), so the conversion
  truncates first.
  """

  use Ecto.Migration

  def up do
    execute("DELETE FROM test_facts")

    alter table(:test_facts) do
      add :valid_at, :tstzrange, null: false
      add :scope_hash, :text, null: false, default: ""
      remove :superseded_by
    end

    execute("ALTER TABLE test_facts DROP CONSTRAINT test_facts_pkey")

    execute("ALTER TABLE test_facts ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)")

    execute("""
    ALTER TABLE test_facts
      ADD CONSTRAINT test_facts_unique_subject_predicate_scope_index
      EXCLUDE USING gist (
        subject_type WITH =,
        subject_id WITH =,
        predicate WITH =,
        scope_hash WITH =,
        valid_at WITH &&
      )
    """)
  end

  def down do
    execute(
      "ALTER TABLE test_facts DROP CONSTRAINT IF EXISTS test_facts_unique_subject_predicate_scope_index"
    )

    execute("ALTER TABLE test_facts DROP CONSTRAINT test_facts_pkey")

    alter table(:test_facts) do
      remove :valid_at
      remove :scope_hash
      add :superseded_by, :uuid
    end

    execute("ALTER TABLE test_facts ADD PRIMARY KEY (id)")
  end
end
