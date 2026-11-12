# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Repo.Migrations.EventLogRecordsAsOf do
  @moduledoc """
  The application time of each write on the test host's event log, which
  ash_events requires for a temporal resource's events (`record_as_of?`):
  `as_of` for a write at an instant, `as_of_range` for one over a period.
  """

  use Ecto.Migration

  def change do
    alter table(:test_event_log) do
      add :as_of, :utc_datetime_usec
      add :as_of_range, :tstzrange
    end
  end
end
