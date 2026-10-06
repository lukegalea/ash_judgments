# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.TestRepo do
  @moduledoc """
  The sandboxed PostgreSQL repo behind the test support app.

  Test-only, like the fixtures it serves: the later CORE tickets record
  judgments on host resources, and a host resource is AshPostgres in this
  programme, so exercising anything ledger-shaped means a real database. The
  library code itself never touches it — `lib/` is data-layer agnostic.
  """

  use AshPostgres.Repo, otp_app: :ash_judgments, warn_on_missing_ash_functions?: false

  # `btree_gist` is the Phase 0 (PostgreSQL 18) temporal-readiness floor: the
  # later temporal surface builds exclusion constraints over range types, and
  # every non-GiST-native column in such a constraint needs this extension.
  # The migration generator diffs this list against the extensions snapshot
  # and emits the CREATE EXTENSION migration when the temporal surface lands.
  # CI runs `postgres:16`, where it is equally available (contrib ships with
  # the server image).
  def installed_extensions, do: ["uuid-ossp", "citext", "ash-functions", "btree_gist"]

  # Phase 0 pins the declared floor to the server the programme develops
  # against (PostgreSQL 18; the ash_enterprise devenv provides 18.4). This is
  # ash_postgres' feature-gating declaration, not a runtime server check.
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
