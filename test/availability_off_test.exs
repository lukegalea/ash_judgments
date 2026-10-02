# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.AvailabilityOffTest do
  # The optional-dep contract's off-path (CORE-PKG/AC-2): with an
  # integration's beam off the code path, the bridge answers with the
  # structured error that names the dependency, and nothing raises. The deps
  # ARE loaded in this repository, so the test removes a code-path entry (in
  # memory only) and restores it. Mutating the node-global code server cannot
  # race another test's use of the modules, hence async: false.
  use ExUnit.Case, async: false

  test "Bridge.Rules.available?/0 names :ash_rules instead of crashing" do
    dir = ebin_dir!(AshRules)
    off!(AshRules, dir)

    assert {:error, {:missing_dependency, :ash_rules}} =
             AshJudgments.Bridge.Rules.available?()

    assert AshJudgments.Availability.active?(:ash_rules) == false

    report = AshJudgments.Availability.report()
    assert Enum.find(report.integrations, &(&1.integration == :ash_rules)).active? == false

    on!(AshRules, dir)
  end

  test "the other bridges degrade the same way for their own dependency" do
    dir = ebin_dir!(AshDecisions)
    off!(AshDecisions, dir)

    assert {:error, {:missing_dependency, :ash_decisions}} =
             AshJudgments.Bridge.Dmn.available?()

    on!(AshDecisions, dir)

    dir = ebin_dir!(AshBpmn)
    off!(AshBpmn, dir)

    assert {:error, {:missing_dependency, :ash_bpmn}} =
             AshJudgments.Bridge.Bpmn.available?()

    on!(AshBpmn, dir)

    dir = ebin_dir!(AshCompliance)
    off!(AshCompliance, dir)

    assert {:error, {:missing_dependency, :ash_compliance}} =
             AshJudgments.Bridge.Evidence.available?()

    on!(AshCompliance, dir)
  end

  # Removes the module's ebin directory from the in-memory code path and
  # purges the loaded copy, so `Code.ensure_loaded?/1` — the activation
  # check — honestly fails. Restored by `on!/2`. The ebin dir is captured
  # BEFORE the removal: once the path entry is gone, the beam is unfindable
  # by `:code.where_is_file/1`.
  defp off!(module, dir) do
    :code.purge(module)
    :code.delete(module)
    :code.del_path(dir)
  end

  defp on!(module, dir) do
    :code.add_path(dir)
    {:module, ^module} = Code.ensure_loaded(module)
  end

  defp ebin_dir!(module) do
    beam = Atom.to_charlist(module) ++ ~c".beam"

    case :code.where_is_file(beam) do
      :non_existing -> flunk("#{inspect(module)} beam not on the code path")
      full -> full |> List.to_string() |> Path.dirname() |> to_charlist()
    end
  end
end
