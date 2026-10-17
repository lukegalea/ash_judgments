#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
#
# Compile this package the way a host with none of its optional
# dependencies does (issue #6): a throwaway Mix project that depends on
# this checkout by path and on nothing else. Optional dependencies never
# enter a consumer's graph unless the consumer declares them, so this host
# has no telemetry_metrics, ash_rules, ash_compliance, ash_bpmn,
# ash_decisions, ash_events, opentelemetry_ash or ash_postgres.
#
# The run fails when:
#   - any of those optional dependencies resolves into the host's graph;
#   - this package does not compile, or its compile emits a warning;
#   - `AshJudgments.Telemetry.Metrics.definitions/0` does not degrade to
#     `{:error, :telemetry_metrics_unavailable}`.
#
# Usage: scripts/no-optional-deps.sh
#
#   NO_OPTIONAL_DEPS_HOST  Where to build the host (default: a new temp
#                          dir). CI sets it so the host's deps and _build
#                          can be cached between runs.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
host="${NO_OPTIONAL_DEPS_HOST:-$(mktemp -d)}"

mkdir -p "$host/lib"

cat >"$host/mix.exs" <<'MIX'
defmodule NoOptionalDepsHost.MixProject do
  use Mix.Project

  def project do
    [app: :no_optional_deps_host, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps, do: [{:ash_judgments, path: System.fetch_env!("ASH_JUDGMENTS_PATH")}]
end
MIX

# Start from this package's lock so the host resolves the versions CI
# tests against; entries the host does not use are dropped below.
cp "$root/mix.lock" "$host/mix.lock"

export ASH_JUDGMENTS_PATH="$root"
export MIX_ENV="${MIX_ENV:-dev}"

cd "$host"

mix deps.get
mix deps.unlock --unused

optional=(telemetry_metrics ash_rules ash_compliance ash_bpmn ash_decisions ash_events opentelemetry_ash ash_postgres)
deps_listing="$(mix deps)"
for dep in "${optional[@]}"; do
  if grep -q "^\* $dep " <<<"$deps_listing"; then
    echo "error: optional dependency $dep is in the host's graph; the check would prove nothing" >&2
    exit 1
  fi
done

# Everything else first, so the forced compile below reports this
# package's warnings and nobody else's.
mix deps.compile

log="$(mktemp)"
mix deps.compile ash_judgments --force 2>&1 | tee "$log"
if grep -q "warning:" "$log"; then
  echo "error: ash_judgments compiled with warnings on a host without its optional dependencies" >&2
  exit 1
fi

mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:ash_judgments)
  false = Code.ensure_loaded?(Telemetry.Metrics)
  {:error, :telemetry_metrics_unavailable} = AshJudgments.Telemetry.Metrics.definitions()
  IO.puts("ash_judgments compiles and degrades without its optional dependencies")
'
