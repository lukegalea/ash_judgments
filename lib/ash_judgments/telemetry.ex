# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Telemetry do
  @moduledoc """
  Judgment telemetry — **ticket AST-90** (CORE-TELEMETRY).

  Re-emits `[:ash_judgments, :judgment, :start | :stop | :exception]` around
  each judge call with metadata: family, question hash, model version, band,
  cache hit, residency, and `region` — because a total that quietly covers
  one region is the most common data error, every metric carries it. Every
  surface shows which rung answered; the metadata carries `rung:
  :system_one`. Plus `:record_failed`, `:pin_mismatch`, `:residency_denied`,
  `:replay_miss` and `:shadow_diff` events, and OpenTelemetry spans (via
  optional `opentelemetry_ash`) mirroring the metadata — sub-processor calls
  carry `ai.disclosure=true`, and every `sub_processor` call produces exactly
  one ledger row (the disclosure record) and one span.

  No state or answer text ever rides in telemetry.

  ## Scope (AST-90)

  - The event set and metadata contract above.
  - Span wiring as a child of the Ash action span.
  - A `Telemetry.Metrics` definitions module for LiveDashboard/Prometheus:
    counters by family × band × region × residency, latency distributions.

  TODO(AST-90): everything above. This module is a scaffold stub — no
  feature logic ships until the ticket lands.
  """
end
