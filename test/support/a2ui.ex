# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The judgment surfaces bound to the test host's resources, as a host binds
# them in its web layer (AshJudgments.A2ui).

defmodule AshJudgments.Test.A2ui.VerdictsUI do
  @moduledoc false
  use AshJudgments.A2ui.Verdicts, resource: AshJudgments.Test.Banding
end

defmodule AshJudgments.Test.A2ui.BandTablesUI do
  @moduledoc false
  use AshJudgments.A2ui.BandTables, resource: AshJudgments.Test.CalibrationRun
end

defmodule AshJudgments.Test.A2ui.CertificationsUI do
  @moduledoc false
  use AshJudgments.A2ui.Certifications, resource: AshJudgments.Test.Certification
end

defmodule AshJudgments.Test.A2ui.CalibrationUI do
  @moduledoc false
  use AshJudgments.A2ui.Calibration, resource: AshJudgments.Test.CalibrationRun
end

defmodule AshJudgments.Test.A2ui.FactsUI do
  @moduledoc false
  use AshJudgments.A2ui.Facts, resource: AshJudgments.Test.Fact
end
