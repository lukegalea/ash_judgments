# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

import Config

# The test support app talks to a real PostgreSQL through the sandboxed
# TestRepo (see test/support/test_repo.ex). `SKIP_DB=1` excludes those tests
# (`:db` tag) for runs without a database; everything else in the suite is
# unaffected.
if System.get_env("SKIP_DB") do
  config :ash_judgments, :db_tests_enabled?, false
else
  config :ash_judgments, :db_tests_enabled?, true
end

config :ash_judgments, ecto_repos: [AshJudgments.TestRepo]

# The stack the registry's judge tests resolve profiles against (the
# profile resolution itself is AST-86's suite). A synthetic model id: the
# package pins no default model.
config :ash_judgments, region: :ca

config :ash_judgments, :profiles, [
  [
    name: :test_local,
    model: "test-model",
    base_url: {:system, "JUDGE_BASE_URL"},
    api_key: {:system, "JUDGE_API_KEY", "local"},
    residency: :in_cluster,
    region: :ca
  ]
]

# The same env pattern ash_agent_tools' test config uses, so the devenv-wrapped
# invocation from ash_enterprise works unchanged:
#
#   cd /home/lukegalea/ash_enterprise && devenv shell -- \
#     bash -c 'cd /home/lukegalea/ast-forks/ash_judgments && mix test'
#
# devenv's Postgres exports PGHOST/PGPORT (the module resolves the port the
# server is actually listening on) and DB_USER/DB_PASSWORD; DB_HOST is honoured
# first for parity with ash_agent_tools, then PGHOST, then the default.
config :ash_judgments, AshJudgments.TestRepo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST") || System.get_env("PGHOST") || "localhost",
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "ash_judgments_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 1000

# Ash loads relationships in spawned Tasks by default; those processes do not
# own the sandbox connection and hit DBConnection.OwnershipError intermittently.
# The standard fix, and what `mix igniter.install ash_postgres` writes.
config :ash, disable_async?: true

# With ash_postgres on the dependency graph, Ash requires an explicit string
# length count (it is what SQL data layers count). Codepoints is the
# recommended setting.
config :ash, default_string_length_count: :codepoints

# This package's test domain is a fixture for the support app, not an
# application domain: it is never meant to land in a host's
# `config :ash_judgments, :ash_domains`. Ash's inclusion validation (active
# with ash_postgres on the graph) would otherwise warn on every run.
config :ash, :validate_domain_config_inclusion?, false
config :ash, :validate_domain_resource_inclusion?, false

config :logger, level: :warning
