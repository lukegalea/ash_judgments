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

  # Canned replies in upstream's raw answer shapes — whatever the question
  # type asks for (`from_answer/2` casts them).
  def evaluate(model_spec, state, questions, _opts) do
    send(self(), {:judge_call, model_spec, state, questions})

    object = Map.new(questions, fn {key, question} -> {key, canned_answer(question)} end)

    {:ok, %{object: object}}
  end

  defp canned_answer(question) do
    case qtype(question) do
      :score -> canned_score()
      :choice -> canned_choice()
      _kind -> %{"probability" => Application.get_env(:ash_judgments, :test_probability, 0.9)}
    end
  end

  # Upstream keeps the question type as an atom in memory.
  defp qtype(question) when is_map(question) do
    type = Map.get(question, :type) || Map.get(question, "type")
    normalize_type(type)
  end

  defp qtype(_other), do: :unknown

  defp normalize_type(nil), do: :unknown
  defp normalize_type(t) when is_atom(t), do: t
  defp normalize_type(t) when is_binary(t), do: String.to_existing_atom(t)
  defp normalize_type(_), do: :unknown

  defp canned_score do
    %{
      "score" => 2,
      "probabilities" => %{"0" => 0.05, "1" => 0.15, "2" => 0.8},
      "confidence" => 0.9,
      "legend" => %{"0" => "None", "1" => "Minor", "2" => "Major"}
    }
  end

  defp canned_choice do
    %{"choice" => "supports", "probabilities" => %{"supports" => 0.9}, "confidence" => 0.9}
  end
end
