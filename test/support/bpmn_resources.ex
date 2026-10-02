# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The six core BPMN engine resources, instantiated on OUR repo and OUR
# domain for the integration fixture (the same shape ash_bpmn's own test
# support uses). Test-only.

defmodule AshJudgments.Test.Bpmn.Definition do
  @moduledoc false
  use AshBpmn.Resources.Definition,
    domain: AshJudgments.Test.Domain,
    repo: AshJudgments.TestRepo

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshJudgments.Test.Bpmn.Instance do
  @moduledoc false
  use AshBpmn.Resources.Instance,
    domain: AshJudgments.Test.Domain,
    repo: AshJudgments.TestRepo,
    definition: AshJudgments.Test.Bpmn.Definition

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshJudgments.Test.Bpmn.Token do
  @moduledoc false
  use AshBpmn.Resources.Token,
    domain: AshJudgments.Test.Domain,
    repo: AshJudgments.TestRepo,
    instance: AshJudgments.Test.Bpmn.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshJudgments.Test.Bpmn.HumanTask do
  @moduledoc false
  use AshBpmn.Resources.HumanTask,
    domain: AshJudgments.Test.Domain,
    repo: AshJudgments.TestRepo,
    instance: AshJudgments.Test.Bpmn.Instance,
    token: AshJudgments.Test.Bpmn.Token

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshJudgments.Test.Bpmn.TaskCandidate do
  @moduledoc false
  use AshBpmn.Resources.TaskCandidate,
    domain: AshJudgments.Test.Domain,
    repo: AshJudgments.TestRepo,
    task: AshJudgments.Test.Bpmn.HumanTask

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshJudgments.Test.Bpmn.ProcessEvent do
  @moduledoc false
  use AshBpmn.Resources.ProcessEvent,
    domain: AshJudgments.Test.Domain,
    repo: AshJudgments.TestRepo,
    instance: AshJudgments.Test.Bpmn.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshJudgments.Test.Bpmn.Domain do
  @moduledoc """
  The BPMN engine's domain: the six core resources + the `ash:call`
  callables allowlist. The extension is TEST-ONLY (ash_bpmn is a
  dev/test-only optional dep; no lib/ module references it — no runtime
  edge, t-core-bridge-placement §0).
  """

  use Ash.Domain, extensions: [AshBpmn.Domain]

  resources do
    resource(AshJudgments.Test.Bpmn.Definition)
    resource(AshJudgments.Test.Bpmn.Instance)
    resource(AshJudgments.Test.Bpmn.Token)
    resource(AshJudgments.Test.Bpmn.HumanTask)
    resource(AshJudgments.Test.Bpmn.TaskCandidate)
    resource(AshJudgments.Test.Bpmn.ProcessEvent)
  end

  callables do
    callable(:judge_note_signals, AshJudgments.Test.BpmnCallables, :judge_note_signals)
    callable(:apply_band, AshJudgments.Test.BpmnCallables, :apply_band)
  end
end
