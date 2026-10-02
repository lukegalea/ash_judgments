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

  def installed_extensions, do: ["uuid-ossp", "citext", "ash-functions"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
