# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Wire.ModelCapture do
  @moduledoc """
  The production wire default: a thin delegating wrapper around
  `ReqLLM.evaluate/4` that captures the runtime-REPORTED model — the
  `model` field of the ReqLLM response, what the provider said answered
  (RFC §5.3's `model_reported`, the `AshAi.Actions.Result.model` of the
  wrapped contract) — into the calling process.

  The judge reads it right after the call (handlers run synchronously
  in the caller's process, so the capture cannot cross wires) and it
  lands in the instrument metadata: the telemetry's `model_version` and
  the recorded observation's `model_version` when the host declared
  none. This closes the AST-89 deferral — the contract-test capture
  existed; this is the production path.

  Endpoints, keys and prompts are never captured: the wrapper reads one
  field and stores one string.
  """

  @moduledoc since: "0.1.0"

  @capture_key {__MODULE__, :model_reported}

  @doc "Delegates to `ReqLLM.evaluate/4`, capturing `response.model`."
  def evaluate(model, state, questions, opts) do
    case ReqLLM.evaluate(model, state, questions, opts) do
      {:ok, response} ->
        capture(response)
        {:ok, response}

      other ->
        other
    end
  end

  @doc "The model the runtime last reported in THIS process, or nil."
  @spec reported_model() :: String.t() | nil
  def reported_model, do: Process.get(@capture_key)

  @doc "Forgets the capture (between calls in long-lived processes)."
  @spec clear() :: :ok
  def clear, do: Process.delete(@capture_key)

  @doc false
  # The capture seam: exposed for tests (the judge-side wiring asserts
  # against it without a live wire).
  def capture(response) do
    case model_of(response) do
      nil -> :ok
      model -> Process.put(@capture_key, model)
    end

    :ok
  end

  defp model_of(%{model: model}) when is_binary(model) and model != "", do: model

  defp model_of(response) when is_map(response) do
    case Map.get(response, :model) || Map.get(response, "model") do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  defp model_of(_other), do: nil
end
