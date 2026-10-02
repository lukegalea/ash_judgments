# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The availability contract is a function over *loaded* modules; make sure
# the test support modules are loaded before any test runs.
[
  AshJudgments.Test.Domain,
  AshJudgments.Test.Note,
  AshJudgments.Test.WorkOrder
]
|> Enum.each(&Code.ensure_loaded!/1)

# The database is created and migrated here, once per test run, so a fresh
# clone needs no setup task; `SKIP_DB=1` excludes the `:db` tests for runs
# without a database. Migrations run outside the sandbox (:auto), and the
# pool is switched to manual ownership afterwards. (Same shape as
# ash_agent_tools' test_helper.exs.)
db_tests? =
  if Application.get_env(:ash_judgments, :db_tests_enabled?, true) do
    {:ok, _} = AshJudgments.TestRepo.start_link()

    Ecto.Adapters.SQL.Sandbox.mode(AshJudgments.TestRepo, :auto)

    case AshJudgments.TestRepo.__adapter__().storage_up(AshJudgments.TestRepo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    Ecto.Migrator.run(AshJudgments.TestRepo, "priv/test_repo/migrations", :up, all: true)

    Ecto.Adapters.SQL.Sandbox.mode(AshJudgments.TestRepo, :manual)
    true
  else
    false
  end

ExUnit.start()

ExUnit.configure(exclude: if(db_tests?, do: [], else: [:db]))

unless db_tests? do
  IO.puts("note: SKIP_DB — excluding the test support app tests (:db tag)")
end
