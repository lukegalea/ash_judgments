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
