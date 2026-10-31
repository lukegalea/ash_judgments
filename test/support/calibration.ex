# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The calibration store's host instantiation (the fragment pattern): the
# runs and the per-family accumulation, on our repo.

defmodule AshJudgments.Test.CalibrationRun do
  @moduledoc false
  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Calibration.Fragment]

  postgres do
    table "test_calibration_runs"
    repo(AshJudgments.TestRepo)
  end

  # The AshJudgments.A2ui.BandTables contract. Publication is host
  # machinery; this host only records that it was asked.
  actions do
    read :awaiting_certification do
      filter expr(
               result == :proposed_table and
                 not exists(AshJudgments.Test.Certification, calibration_run_id == parent(id))
             )
    end

    action :certify_and_publish, :map do
      argument :record_id, :uuid, allow_nil?: false
      run fn input, _context -> {:ok, %{certified: input.arguments.record_id}} end
    end
  end
end

defmodule AshJudgments.Test.CalibrationSample do
  @moduledoc false
  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshJudgments.Calibration.SampleFragment]

  postgres do
    table "test_calibration_samples"
    repo(AshJudgments.TestRepo)
  end
end
