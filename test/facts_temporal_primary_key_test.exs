# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.FactsTemporalPrimaryKeyTest do
  @moduledoc """
  A temporal facts host whose table lacks its primary key reaches
  `PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)` through a generated
  migration (`AshJudgments.Facts.TemporalPrimaryKey`).

  The host's history is rebuilt in a scratch snapshot and migration
  directory: the generator creates the table, the primary key is dropped
  (the state a hand-written migration leaves behind, with a snapshot that
  still records the key), and `--check` passes because the generator
  cannot see the gap. Adding the repair statement to the resource makes
  the generator emit a migration that adds the key, and `--check` passes
  again afterwards.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Facts.TemporalPrimaryKey
  alias AshJudgments.TestRepo

  @moduletag :db

  @table "pk_repair_facts"

  setup do
    # The migrator takes connections of its own (its lock and its runner),
    # so the pool runs unsandboxed here, as it does for test_helper's
    # migrations.
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)

    # The generator reports each file it writes; keep that out of the run.
    Mix.shell(Mix.Shell.Process)

    tmp = Path.join(System.tmp_dir!(), "aj-pk-repair-#{System.unique_integer([:positive])}")
    snapshots = Path.join(tmp, "snapshots")
    migrations = Path.join(tmp, "migrations")

    # The repo's extensions are already installed and recorded; copying
    # their snapshot keeps the generator to the facts table.
    File.mkdir_p!(Path.join(snapshots, "test_repo"))
    File.mkdir_p!(migrations)

    File.cp!(
      "priv/resource_snapshots/test_repo/extensions.json",
      Path.join([snapshots, "test_repo", "extensions.json"])
    )

    TestRepo.query!("DROP TABLE IF EXISTS #{@table}")

    on_exit(fn ->
      TestRepo.query!("DROP TABLE IF EXISTS #{@table}")

      versions =
        migrations
        |> Path.join("*.exs")
        |> Path.wildcard()
        |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))

      TestRepo.query!("DELETE FROM schema_migrations WHERE version = ANY($1)", [versions])
      File.rm_rf!(tmp)
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      Mix.shell(Mix.Shell.IO)
    end)

    %{snapshots: snapshots, migrations: migrations}
  end

  test "a table without its primary key gets it from a generated migration", ctx do
    # 1. The table as the generator creates it, then without its key.
    generate(AshJudgments.Test.PkRepair.BrokenDomain, ctx, name: unique("create_pk_repair_facts"))
    [create] = migration_files(ctx)
    migrate(create)

    assert primary_key() ==
             {"pk_repair_facts_pkey", "PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"}

    TestRepo.query!("ALTER TABLE #{@table} DROP CONSTRAINT pk_repair_facts_pkey")
    assert primary_key() == nil

    # 2. The generator cannot see the missing key: the snapshot records
    # `id` as the primary key and the resource agrees.
    assert :ok == generate(AshJudgments.Test.PkRepair.BrokenDomain, ctx, check: true)

    # 3. The repair statement on the resource: one generated migration,
    # which adds the key and drops nothing.
    generate(AshJudgments.Test.PkRepair.RepairedDomain, ctx,
      name: unique("pk_repair_facts_temporal_pkey")
    )

    [repair] = migration_files(ctx) -- [create]
    source = File.read!(repair)

    assert source =~ "ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"
    refute source =~ "drop constraint"

    migrate(repair)

    assert primary_key() ==
             {"pk_repair_facts_pkey", "PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"}

    # 4. Nothing left to generate.
    assert :ok == generate(AshJudgments.Test.PkRepair.RepairedDomain, ctx, check: true)

    # 5. The statement is idempotent: a table that already has the key is
    # left alone.
    TestRepo.query!(TemporalPrimaryKey.repair_up(@table))

    assert primary_key() ==
             {"pk_repair_facts_pkey", "PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"}
  end

  test "the repair refuses a primary key that is not temporal", ctx do
    generate(AshJudgments.Test.PkRepair.BrokenDomain, ctx, name: unique("create_pk_repair_facts"))
    [create] = migration_files(ctx)
    migrate(create)

    TestRepo.query!("ALTER TABLE #{@table} DROP CONSTRAINT pk_repair_facts_pkey")
    TestRepo.query!("ALTER TABLE #{@table} ADD PRIMARY KEY (id)")

    error =
      assert_raise Postgrex.Error, fn -> TestRepo.query!(TemporalPrimaryKey.repair_up(@table)) end

    assert Exception.message(error) =~ "has a primary key that is not temporal: PRIMARY KEY (id)"
  end

  test "the down statement leaves the key in place", ctx do
    generate(AshJudgments.Test.PkRepair.BrokenDomain, ctx, name: unique("create_pk_repair_facts"))
    [create] = migration_files(ctx)
    migrate(create)

    TestRepo.query!(TemporalPrimaryKey.repair_down(@table))

    assert primary_key() ==
             {"pk_repair_facts_pkey", "PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"}
  end

  test "a schema-qualified table" do
    assert TemporalPrimaryKey.repair_up(@table, schema: "facts") =~
             ~s(ALTER TABLE "facts"."#{@table}" ADD PRIMARY KEY)
  end

  defp generate(domain, ctx, opts) do
    AshPostgres.MigrationGenerator.generate(
      domain,
      [
        snapshot_path: ctx.snapshots,
        migration_path: ctx.migrations,
        quiet: true,
        format: false
      ] ++ opts
    )
  end

  # Each test compiles its own migration modules; distinct names keep them
  # from redefining one another.
  defp unique(name), do: "#{name}_#{System.unique_integer([:positive])}"

  defp migration_files(ctx) do
    ctx.migrations |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()
  end

  defp migrate(file) do
    [{module, _}] = Code.compile_file(file)
    version = file |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()
    :ok = Ecto.Migrator.up(TestRepo, version, module, log: false)
  end

  defp primary_key do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT conname, pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conrelid = to_regclass($1) AND contype = 'p'
        """,
        [@table]
      )

    case rows do
      [] -> nil
      [[name, definition]] -> {name, definition}
    end
  end
end
