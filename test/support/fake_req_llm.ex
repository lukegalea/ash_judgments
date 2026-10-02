# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.FakeReqLLM do
  @moduledoc """
  The ReqLLM stand-in for the registry's judge tests (AC-5).

  Upstream `evaluate` accepts a `:req_llm` module override "useful for
  testing with mocks"; this fake uses it to capture what would go over the
  wire — the resolved model spec, the projected state, the question map —
  and to answer with a canned reply, so the test asserts on the request
  without a model. It runs in the caller's process, so `send(self(), ...)`
  hands the capture to the test.
  """

  # The probes are Noul questions; this is upstream's raw answer shape,
  # which `AshAi.Evaluate.Noul.from_answer/2` casts.
  @canned_noul %{"probability" => 0.9}

  def evaluate(model_spec, state, questions, _opts) do
    send(self(), {:judge_call, model_spec, state, questions})

    object = Map.new(questions, fn {key, _question} -> {key, @canned_noul} end)

    {:ok, %{object: object}}
  end
end
