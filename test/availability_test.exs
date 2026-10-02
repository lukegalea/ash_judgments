# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.AvailabilityTest do
  use ExUnit.Case, async: true

  describe "report/0" do
    test "lists every optional integration, never raises, and is JSON-encodable" do
      report = AshJudgments.Availability.report()

      names =
        report.integrations
        |> Enum.map(& &1.integration)
        |> Enum.sort()

      assert names == [
               :ash_bpmn,
               :ash_compliance,
               :ash_decisions,
               :ash_events,
               :ash_rules,
               :opentelemetry_ash
             ]

      # Plain data all the way down: a host can drop this straight into a
      # discovery response.
      assert Jason.encode!(report)
    end

    test "each entry names the dep to add and the consumers that need it" do
      for entry <- AshJudgments.Availability.report().integrations do
        assert is_binary(entry.dep) and entry.dep != ""
        assert entry.consumers != []
        assert is_binary(entry.concept) and entry.concept != ""
        assert is_boolean(entry.active?)
      end
    end
  end

  describe "active?/1 and ensure/1" do
    test "an unknown integration is inactive and degrades to the structured error" do
      refute AshJudgments.Availability.active?(:definitely_not_an_integration)

      assert {:error, {:missing_dependency, :definitely_not_an_integration}} =
               AshJudgments.Availability.ensure(:definitely_not_an_integration)
    end

    test "a loaded integration is active" do
      # This repository ships the optional deps, so their marker modules are
      # loaded here; the off-path is exercised in the AvailabilityOffTest.
      assert AshJudgments.Availability.active?(:ash_rules)
      assert AshJudgments.Availability.ensure(:ash_rules) == :ok
    end
  end

  describe "ensure_active!/1" do
    test "raises the structured error that names the dep to add" do
      assert_raise ArgumentError,
                   ~r/ash_rules tooling is not available: add \{:ash_rules, github: "lukegalea\/ash_rules"\}/,
                   fn ->
                     absent_active!(:ash_rules)
                   end
    end

    test "raises on an unknown integration name" do
      assert_raise ArgumentError, ~r/unknown optional integration/, fn ->
        AshJudgments.Availability.ensure_active!(:nope)
      end
    end

    # A helper so the happy path of ensure_active!/1 is exercised without
    # depending on which optional deps this repository happens to ship.
    defp absent_active!(integration) do
      with_marker_off(integration, fn ->
        AshJudgments.Availability.ensure_active!(integration)
      end)
    end

    defp with_marker_off(integration, fun) do
      module = integration_module!(integration)
      dir = ebin_dir!(module)

      :code.purge(module)
      :code.delete(module)
      :code.del_path(dir)

      try do
        fun.()
      after
        :code.add_path(dir)
        {:module, ^module} = Code.ensure_loaded(module)
      end
    end

    defp integration_module!(integration) do
      Enum.find(AshJudgments.Availability.integrations(), &(&1.integration == integration)).module
    end

    defp ebin_dir!(module) do
      beam = Atom.to_charlist(module) ++ ~c".beam"

      case :code.where_is_file(beam) do
        :non_existing -> flunk("#{inspect(module)} beam not on the code path")
        full -> full |> List.to_string() |> Path.dirname() |> to_charlist()
      end
    end
  end
end
