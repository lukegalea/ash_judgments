# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.ProfileHelpers do
  @moduledoc """
  Shared builders for the profile tests: two canonical profiles (one local
  in-cluster, one hosted sub-processor — synthetic ids only) and the node
  global setup/teardown the resolution guards read (Application env,
  environment variables).
  """

  import ExUnit.Callbacks

  @doc "A local, in-cluster profile. Keyword overrides merge."
  def local_profile(overrides \\ []) do
    AshJudgments.Profile.new!(
      Keyword.merge(
        [
          name: :local,
          model: "winnow:e4b",
          base_url: {:system, "OLLAYA_BASE_URL"},
          api_key: {:system, "OLLAYA_API_KEY", "local"},
          residency: :in_cluster,
          region: :ca
        ],
        overrides
      )
    )
  end

  @doc "A hosted, sub-processor profile (the class the tenant opt-out governs)."
  def hosted_profile(overrides \\ []) do
    AshJudgments.Profile.new!(
      Keyword.merge(
        [
          name: :hosted,
          model: "jev-1.13.0",
          api_key: {:system, "TYPESAFE_API_KEY"},
          residency: :sub_processor,
          region: :ca
        ],
        overrides
      )
    )
  end

  @doc """
  Setup: a clean, known stack — region declared, no routes, default policy
  — with every mutation restored on exit.
  """
  def configure_stack(_context) do
    # The profile REGISTRY (:profiles, from config/test.exs) is left alone:
    # the judge tests resolve :test_local through it. Only the resolution
    # GUARDS get a clean slate, with every mutation restored on exit.
    keys = [:region, :model_routes, :residency_policy, :test_residency_decisions]
    restore = capture_env(keys)
    Application.put_env(:ash_judgments, :region, :ca)
    Enum.each(List.delete(keys, :region), &Application.delete_env(:ash_judgments, &1))

    on_exit(fn -> restore_env(restore) end)

    :ok
  end

  defp capture_env(keys) do
    Enum.map(keys, &{&1, Application.get_env(:ash_judgments, &1)})
  end

  defp restore_env(restore) do
    for {key, value} <- restore do
      if value == nil do
        Application.delete_env(:ash_judgments, key)
      else
        Application.put_env(:ash_judgments, key, value)
      end
    end
  end

  @doc """
  Sets environment variables for the current test, restoring the previous
  value (or deleting what we added) after. Restore, not delete: a variable
  the operator exported (OLLAYA_BASE_URL for the contract suite) must
  survive the test that re-set it to the same value.
  """
  def put_test_env(vars) do
    previous = capture_system_env(Map.keys(vars))
    set_system_env(vars)

    on_exit(fn -> restore_system_env(previous) end)

    :ok
  end

  defp capture_system_env(vars) do
    Map.new(vars, fn var -> {var, System.get_env(var)} end)
  end

  defp set_system_env(vars) do
    Enum.each(vars, fn {var, value} -> System.put_env(var, value) end)
  end

  defp restore_system_env(previous) do
    for {var, old} <- previous do
      if old == nil do
        System.delete_env(var)
      else
        System.put_env(var, old)
      end
    end
  end
end
