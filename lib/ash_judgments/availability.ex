# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Availability do
  @moduledoc """
  Which optional concept integrations are active in this VM.

  The bridges (DMN, rules, BPMN, evidence) and the OpenTelemetry span wiring
  arrive behind **optional** dependencies: hosts add the dep, the integration
  activates. Nothing is forced on hosts that do not need the concept, and a
  missing dep is never a compile-time problem — every integration is gated
  behind `Code.ensure_loaded?/1` conditional compilation (the Ecto-Jason
  pattern), so this package compiles cleanly with or without any of them.

  At runtime, a bridge whose integration is absent answers with a structured
  error that names the dep to add, and never raises:

      AshJudgments.Bridge.Rules.available?()
      #=> {:error, {:missing_dependency, :ash_rules}}

  `report/0` is the discovery side of that contract: one entry per optional
  integration with its activation status, the dep to add, and what it
  unlocks. The pattern is copied from `AshAgentTools.Availability`.
  """

  @type integration ::
          :ash_rules
          | :ash_compliance
          | :ash_bpmn
          | :ash_decisions
          | :ash_events
          | :opentelemetry_ash

  @integrations [
    %{
      integration: :ash_rules,
      module: AshRules,
      dep: ~s({:ash_rules, github: "lukegalea/ash_rules"}),
      consumers: [AshJudgments.Bridge.Rules],
      concept: "crisp rule evaluation over admitted facts; escalate means omit"
    },
    %{
      integration: :ash_compliance,
      module: AshCompliance,
      dep: ~s({:ash_compliance, github: "lukegalea/ash_compliance"}),
      consumers: [AshJudgments.Bridge.Evidence],
      concept: "EvidenceArtifact mapping: model-derived evidence with chain of custody"
    },
    %{
      integration: :ash_bpmn,
      module: AshBpmn,
      dep: ~s({:ash_bpmn, github: "lukegalea/ash_bpmn"}),
      consumers: [AshJudgments.Bridge.Bpmn],
      concept: "callable judge actions as `ash:call` service tasks returning flat scalars"
    },
    %{
      integration: :ash_decisions,
      module: AshDecisions,
      dep: ~s({:ash_decisions, github: "lukegalea/ash_decisions"}),
      consumers: [AshJudgments.Bridge.Dmn, AshJudgments.Calibration],
      concept: "DMN band tables: the only place a probability becomes an admission"
    },
    %{
      integration: :ash_events,
      module: AshEvents,
      dep: ~s({:ash_events, "~> 0.7"}),
      consumers: [AshJudgments.Ledger],
      concept: "record-don't-recompute: replay consumes recorded judgments, never re-runs them"
    },
    %{
      integration: :opentelemetry_ash,
      module: OpentelemetryAsh,
      dep: ~s({:opentelemetry_ash, "~> 0.1"}),
      consumers: [AshJudgments.Telemetry],
      concept: "a span per judge call as a child of the Ash action span"
    }
  ]

  @doc """
  The optional integrations this package knows about, as plain data:
  `:integration`, the module that marks it loaded, the `:dep` to add, the
  `:consumers` that require it, and the `:concept` it serves.
  """
  @spec integrations() :: [map()]
  def integrations, do: @integrations

  @doc """
  Whether the optional integration is active: its marker module is loaded
  (which for a host application means it ships the dep).
  """
  @spec active?(integration()) :: boolean()
  def active?(integration) do
    case fetch(integration) do
      %{module: module} -> Code.ensure_loaded?(module)
      nil -> false
    end
  end

  @doc """
  `:ok` when the integration is active, otherwise
  `{:error, {:missing_dependency, integration}}` — the structured,
  never-raising form the bridges return from their `available?/0`.
  """
  @spec ensure(integration()) :: :ok | {:error, {:missing_dependency, integration()}}
  def ensure(integration) do
    if active?(integration) do
      :ok
    else
      {:error, {:missing_dependency, integration}}
    end
  end

  @doc """
  The availability report: one entry per optional integration, sorted by
  name. Plain and JSON-encodable; never raises.
  """
  @spec report() :: map()
  def report do
    %{
      integrations:
        @integrations
        |> Enum.map(fn integration ->
          %{
            integration: integration.integration,
            active?: active?(integration.integration),
            dep: integration.dep,
            consumers: integration.consumers,
            concept: integration.concept
          }
        end)
        |> Enum.sort_by(& &1.integration)
    }
  end

  @doc """
  Raises the structured "not available" error for an inactive integration:
  it names the dep to add, so the agent (or the human behind it) can fix the
  environment in one step. The happy path is silence — an active integration
  returns `:ok`.
  """
  @spec ensure_active!(integration()) :: :ok
  def ensure_active!(integration) do
    case fetch(integration) do
      %{dep: dep} ->
        unless active?(integration) do
          raise ArgumentError,
                "#{Atom.to_string(integration)} tooling is not available:" <>
                  " add #{dep} to your deps to use this" <>
                  " (see AshJudgments.Availability.report/0)"
        end

        :ok

      nil ->
        raise ArgumentError, "unknown optional integration #{inspect(integration)}"
    end
  end

  defp fetch(integration) do
    Enum.find(@integrations, &(&1.integration == integration))
  end
end
