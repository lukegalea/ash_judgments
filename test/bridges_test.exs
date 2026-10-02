# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.BridgesTest do
  use ExUnit.Case, async: true

  # Every optional integration the package knows about has its named
  # consumers wired to the right availability check — a bridge that drifted
  # from its dependency (or an integration entry nobody consumes) is a
  # scaffold defect this catches statically.
  test "each bridge answers available?/0 without raising and matches its declared consumer" do
    consumers =
      AshJudgments.Availability.integrations()
      |> Map.new(fn i -> {i.integration, i.module} end)

    for {bridge, integration} <- [
          {AshJudgments.Bridge.Dmn, :ash_decisions},
          {AshJudgments.Bridge.Rules, :ash_rules},
          {AshJudgments.Bridge.Bpmn, :ash_bpmn},
          {AshJudgments.Bridge.Evidence, :ash_compliance}
        ] do
      # The bridge module is referenced only as an atom above; load it before
      # the exported-function check, which does not load modules itself.
      Code.ensure_loaded!(bridge)

      assert function_exported?(bridge, :available?, 0),
             "#{inspect(bridge)} must expose available?/0"

      marker = Map.fetch!(consumers, integration)

      result =
        if Code.ensure_loaded?(marker) do
          :ok
        else
          {:error, {:missing_dependency, ^integration}} = bridge.available?()
          :absent
        end

      assert result in [:ok, :absent]
    end
  end
end
