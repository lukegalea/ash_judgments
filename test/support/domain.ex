# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Domain do
  @moduledoc """
  The Ash domain of the test support app.

  A fixture, not an application domain: synthetic resources that give the
  tickets a subject to judge, a facts table to read, and surfaces to
  bridge. Nothing here is customer-related; nothing here lands in a
  host's domain config.
  """

  use Ash.Domain

  resources do
    resource(AshJudgments.Test.BpmnCallables)
    resource(AshJudgments.Test.Note)
    resource(AshJudgments.Test.WorkOrder)
    resource(AshJudgments.Test.Appointment)

    # The instrument probe (generic actions, no data) — it lives on the
    # domain because Ash refuses to run actions for resources the domain
    # does not accept.
    resource(AshJudgments.Test.InstrumentProbe)
    resource(AshJudgments.Test.Judgment)
    resource(AshJudgments.Test.HumanVerdict)
    resource(AshJudgments.Test.QuestionProposal)
    resource(AshJudgments.Test.EventLog)
    resource(AshJudgments.Test.Fact)
    resource(AshJudgments.Test.FailingLedger)
    resource(AshJudgments.Test.CountingLedger)
    resource(AshJudgments.Test.Banding)
    resource(AshJudgments.Test.Certification)

    # The calibration store (AST-91): the §8.1 runs + the accumulation.
    resource(AshJudgments.Test.CalibrationRun)
    resource(AshJudgments.Test.CalibrationSample)

    # The BPMN engine resources (AST-94 integration): the six core kinds,
    # instantiated on our repo. TEST-ONLY — ash_bpmn is a dev/test-only
    # optional dep and no lib/ module references it.
    resource(AshJudgments.Test.Bpmn.Definition)
    resource(AshJudgments.Test.Bpmn.Instance)
    resource(AshJudgments.Test.Bpmn.Token)
    resource(AshJudgments.Test.Bpmn.HumanTask)
    resource(AshJudgments.Test.Bpmn.TaskCandidate)
    resource(AshJudgments.Test.Bpmn.ProcessEvent)
  end
end
