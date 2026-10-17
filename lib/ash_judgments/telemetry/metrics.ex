# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Telemetry.Metrics do
  @moduledoc """
  The `:telemetry_metrics` definitions for the judgment events — plug
  into LiveDashboard or a Prometheus reporter:

      children = [
        {TelemetryMetricsPrometheus, [metrics: AshJudgments.Telemetry.Metrics.definitions()]}
      ]

  Counters carry `family`, `region`, `residency` and `mode` — a total
  that quietly covers one region is the org's most common data error
  (law 10) — and the latency distributions ride the judge `:stop`
  event's `latency_us` measurement. No metric tag ever carries answer
  or state content (envelope-class keys only).
  """

  @moduledoc since: "0.1.0"

  # `telemetry_metrics` is an OPTIONAL dependency (the package's own
  # contract is the events; the metrics definitions are the plug-in
  # form). Absent, `definitions/0` degrades — never raises.
  #
  # The builder calls below are fully qualified remote calls, never an
  # `import`: an import resolves at compile time and fails to compile on a
  # host without the dependency (issue #6). A remote call to a missing
  # module compiles; only its undefined-module warning is silenced here.
  @compile {:no_warn_undefined, Telemetry.Metrics}

  alias Telemetry.Metrics

  @doc """
  The metric definitions, as data. `{:error, :telemetry_metrics_unavailable}`
  when the optional `telemetry_metrics` dependency is absent.
  """
  @spec definitions() :: list() | {:error, :telemetry_metrics_unavailable}
  def definitions do
    # Sourced from env (default the real module): a runtime value keeps
    # the compiler from narrowing ensure_loaded? on hosts without the
    # optional dep, and lets a host rename the module if it must.
    metrics = Application.get_env(:ash_judgments, :telemetry_metrics_module, Telemetry.Metrics)

    if Code.ensure_loaded?(metrics) do
      definitions!()
    else
      {:error, :telemetry_metrics_unavailable}
    end
  end

  @doc """
  The metric definitions when `telemetry_metrics` is available. Without
  it this raises `UndefinedFunctionError`; call `definitions/0` when the
  dependency may be absent.
  """
  @spec definitions!() :: list()
  def definitions! do
    [
      # The judge call itself: one counter per family × region × residency ×
      # mode (the outcome rides the exception/record-failure counters).
      Metrics.counter("ash_judgments.judgment.stop.count",
        tags: [:family, :region, :residency, :mode, :cache_hit?]
      ),
      Metrics.counter("ash_judgments.judgment.exception.count",
        tags: [:family, :region, :residency, :kind]
      ),
      # Latency distributions: the wire latency and the full-call duration.
      Metrics.distribution("ash_judgments.judgment.stop.latency_us",
        tags: [:family, :region],
        unit: {:native, :microsecond}
      ),
      Metrics.distribution("ash_judgments.judgment.stop.duration",
        tags: [:family, :region],
        unit: {:native, :microsecond}
      ),
      # Cache and shadow outcomes.
      Metrics.counter("ash_judgments.cache.hit.count", tags: [:region, :residency, :mode]),
      Metrics.counter("ash_judgments.cache.replay_miss.count", tags: [:region, :mode]),
      Metrics.counter("ash_judgments.shadow.diff.count", tags: [:region, :mode]),
      # The refusal/failure surfaces.
      Metrics.counter("ash_judgments.record.failed.count", tags: [:family, :region, :record]),
      Metrics.counter("ash_judgments.residency.denied.count",
        tags: [:region, :residency, :profile]
      ),
      Metrics.counter("ash_judgments.pin.mismatch.count", tags: [:region]),
      # The ledger/facts surfaces.
      Metrics.counter("ash_judgments.ledger.tombstoned.count", tags: [:region]),
      Metrics.counter("ash_judgments.facts.materialised.count", tags: [:region, :grade, :verdict])
    ]
  end
end
