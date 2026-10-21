# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Facts.TemporalPrimaryKey do
  @moduledoc """
  SQL for a host whose temporal facts table is missing its primary key.

  `AshJudgments.Facts.TemporalFragment` declares `id` as the primary key
  of a temporal resource, and the migration generator turns that into
  `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)` when it creates the table.
  A table created some other way (a hand-written migration, for example)
  can lack that key while the resource snapshot still records it. The
  generator cannot see the gap: it only changes a primary key when the
  snapshot's key changes, and when it does, it first drops
  `<table>_pkey`, which such a table does not have.

  The repair is an `ash_postgres` custom statement on the host's facts
  resource, so the migration is still generated:

      postgres do
        table "my_facts"
        repo MyApp.Repo

        custom_statements do
          statement :my_facts_temporal_primary_key do
            up AshJudgments.Facts.TemporalPrimaryKey.repair_up("my_facts")
            down AshJudgments.Facts.TemporalPrimaryKey.repair_down("my_facts")
          end
        end
      end

  Then run `mix ash.codegen <name>` and migrate. Postgres names the new
  constraint `my_facts_pkey`, the name Ash expects.

  `repair_up/2` is safe on any table:

  - no primary key: it adds `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`;
  - the temporal primary key already exists: it does nothing;
  - some other primary key exists: it raises, naming the key it found,
    rather than replace a key that other constraints may depend on.

  Adding the key fails if any row has an empty `valid_at`, because a
  `WITHOUT OVERLAPS` key rejects empty ranges. Check first with
  `SELECT count(*) FROM my_facts WHERE isempty(valid_at)`.

  `repair_down/2` does not drop the key. The key belongs to the resource
  (the snapshot already records it), so rolling the repair back, or later
  deleting the custom statement, leaves the table as the resource
  describes it.
  """

  @moduledoc since: "0.3.2"

  @doc """
  The `up` statement: adds the temporal primary key when the table has
  none. `opts`: `:schema` (default: unqualified, the search path).
  """
  @doc since: "0.3.2"
  @spec repair_up(String.t(), keyword()) :: String.t()
  def repair_up(table, opts \\ []) when is_binary(table) do
    relation = relation(table, opts)

    """
    DO $repair$
    DECLARE
      existing text;
      temporal boolean;
    BEGIN
      SELECT pg_get_constraintdef(oid), conperiod INTO existing, temporal
      FROM pg_constraint
      WHERE conrelid = to_regclass('#{relation}') AND contype = 'p';

      IF existing IS NULL THEN
        ALTER TABLE #{relation} ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS);
      ELSIF NOT temporal THEN
        RAISE EXCEPTION '#{table} has a primary key that is not temporal: %', existing;
      END IF;
    END
    $repair$
    """
  end

  @doc """
  The `down` statement: leaves the primary key in place (see the
  moduledoc). It takes the same arguments as `repair_up/2` so the two
  read alike in the resource.
  """
  @doc since: "0.3.2"
  @spec repair_down(String.t(), keyword()) :: String.t()
  def repair_down(table, _opts \\ []) when is_binary(table) do
    """
    DO $repair$
    BEGIN
      RAISE NOTICE '#{table}: the temporal primary key belongs to the resource; nothing to undo';
    END
    $repair$
    """
  end

  defp relation(table, opts) do
    case Keyword.get(opts, :schema) do
      nil -> ~s("#{table}")
      schema -> ~s("#{schema}"."#{table}")
    end
  end
end
