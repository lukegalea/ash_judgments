# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Telemetry.OtelEmitter do
  @moduledoc """
  The default span emitter for `AshJudgments.Telemetry.attach_otel/1`:
  speaks the `:opentelemetry` application's API. Loaded-or-not is
  checked by `attach_otel/1` before this module is called — a host
  without the SDK attaches nothing and the package stays
  telemetry-only.
  """

  @moduledoc since: "0.1.0"

  @span_table :ash_judgments_otel_spans

  # Every SDK call is DYNAMIC (`apply/3` behind an export check): the
  # package holds no hard or compile-time edge to the OTel SDK, and an
  # SDK without the expected exports degrades to no-op spans rather than
  # crashing the judge path. Spans are tracked per-process (the judge
  # call is single-process; the handler runs synchronously in it).

  def start_span(name, attributes) do
    ensure_table()

    with true <- sdk?(),
         span_ctx when span_ctx != :undefined <-
           sdk_start_span(name, attributes) do
      Process.put({@span_table, self_key(name)}, span_ctx)
    end

    :ok
  end

  def end_span(name, _measurements) do
    with span_ctx when span_ctx != nil <- Process.get({@span_table, self_key(name)}),
         true <- sdk?() do
      sdk_end_span(span_ctx)
    end

    Process.delete({@span_table, self_key(name)})
    :ok
  end

  def record_exception(name, kind, _measurements) do
    with span_ctx when span_ctx != nil <- Process.get({@span_table, self_key(name)}),
         true <- sdk?() do
      sdk_record_exception(span_ctx, kind)
      sdk_end_span(span_ctx)
    end

    Process.delete({@span_table, self_key(name)})
    :ok
  end

  defp self_key(name), do: {self(), name}

  defp sdk? do
    # Sourced from env (default the real module): a runtime value keeps
    # the compiler from narrowing ensure_loaded? on hosts without the SDK.
    sdk = Application.get_env(:ash_judgments, :otel_module, :opentelemetry)

    Code.ensure_loaded?(sdk) and function_exported?(sdk, :start_span, 3)
  end

  # credo: apply/3 is deliberate — a DIRECT call would be a compile-time
  # edge to an SDK the host may not ship.
  defp sdk_start_span(name, attributes) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(sdk(), :start_span, [name, %{}, attributes])
  rescue
    _ -> :undefined
  end

  defp sdk_end_span(span_ctx) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(sdk(), :end_span, [span_ctx])
  rescue
    _ -> :ok
  end

  defp sdk_record_exception(span_ctx, kind) do
    sdk = sdk()

    if function_exported?(sdk, :record_exception, 3) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(sdk, :record_exception, [span_ctx, kind, %{}])
    end
  rescue
    _ -> :ok
  end

  defp sdk, do: Application.get_env(:ash_judgments, :otel_module, :opentelemetry)

  defp ensure_table do
    if :ets.whereis(@span_table) == :undefined do
      :ets.new(@span_table, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end
end
