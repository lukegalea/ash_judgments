# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.Banding.Display do
  @moduledoc """
  Reads a banding's flattened DMN inputs (`AshJudgments.Bridge.Dmn.inputs/2`)
  back into what a person reviewing it needs: the family, the question
  and the score the band table gated on. These are the banding fragment's
  `:family`, `:question` and `:score` calculations. They are for display
  only: the inputs are recorded as the evaluation consumed them, and
  nothing here recomputes a band.

  - `:family`: the `family` envelope input.
  - `:question`: the question whose answer is present (`<question>__present`
    is `"true"`); with several, they are joined by `", "`.
  - `:score`: that question's `p_true` (yes/no) or `confidence` (choice),
    as the decimal string the table read.
  """
  @moduledoc since: "0.3.3"

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:inputs]

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, &display(&1.inputs || %{}, opts[:field]))
  end

  defp display(inputs, :family), do: inputs["family"]

  defp display(inputs, :question) do
    case questions(inputs) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp display(inputs, :score) do
    case questions(inputs) do
      [name | _] -> inputs["#{name}__p_true"] || inputs["#{name}__confidence"]
      [] -> nil
    end
  end

  @doc false
  # The questions whose answer is present in a banding's inputs, sorted.
  def questions(inputs) do
    for {key, "true"} <- inputs, String.ends_with?(key, "__present"), into: [] do
      String.replace_suffix(key, "__present", "")
    end
    |> Enum.sort()
  end
end
