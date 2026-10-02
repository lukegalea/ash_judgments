# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The test host's BPMN seams: the `ash:call` callables and the assignment
# resolver. Test-only — ash_bpmn is a DEV/TEST-ONLY optional dependency
# with no runtime edge to this package's lib/ (the DAG in
# t-core-bridge-placement §0 forbids it in both directions).

defmodule AshJudgments.Test.BpmnCallables do
  @moduledoc """
  The BPMN `ash:call` surface for the standing-evaluation fixture.

  `judge_note_signals` wraps the subject's text into the projection input
  and delegates to the Note resource's GENERATED signals action — the
  judge path (state projection, profile resolution, recorder) is the
  registry's, and the engine's caller context passes through UNCHANGED:
  the package injects no actor ([L]4 — where a process runs unattended,
  the host wires its automation principal).

  `apply_band` is the band-table step's seam: it reads the promoted
  probability off the token's routing and returns the flat scalar band
  the gateway routes on.
  """

  use Ash.Resource, domain: AshJudgments.Test.Domain

  actions do
    # The fixture's judged-signals callable: takes the subject's text
    # field and wraps it into the projection input the judge needs.
    action :judge_note_signals, :map do
      argument :input, :string, allow_nil?: false, public?: true

      run fn input, _context ->
        text = Ash.ActionInput.get_argument(input, :input)

        # The engine scope replaces the action context with its own, so the
        # host's judgments context (req_llm override, mode) rides in here —
        # the same way a host wires its automation principal ([L]4).
        ctx =
          input.context
          |> Map.put(:judgments, Application.get_env(:ash_judgments, :test_judgments_ctx, %{}))

        AshJudgments.Test.Note
        |> Ash.ActionInput.for_action(:judge_notes_follow_up_signals, %{
          "input" => %{"text" => text}
        })
        |> Ash.run_action(context: ctx)
      end
    end

    # The band-table seam: bands the promoted probability (a DECIMAL
    # STRING, per the scalar-promotion discipline — canonical JSON).
    # p >= 0.9 admits, p >= 0.5 reviews, else omits.
    action :apply_band, :map do
      argument :probability, :string, allow_nil?: false, public?: true

      run fn input, _context ->
        p = Ash.ActionInput.get_argument(input, :probability)
        {decimal, ""} = Decimal.parse(p)

        band =
          if Decimal.compare(decimal, "0.9") in [:gt, :eq] do
            "admit"
          else
            if Decimal.compare(decimal, "0.5") in [:gt, :eq], do: "review", else: "omit"
          end

        {:ok, %{"band" => band}}
      end
    end
  end
end

defmodule AshJudgments.Test.BpmnResolver do
  @moduledoc """
  The assignment resolver seam: every review task goes to one synthetic
  reviewer principal. Stable per test run; nothing real behind it.
  """

  @reviewer "11111111-1111-4111-8111-111111111111"

  def candidates(_specs, _ctx), do: {:ok, [%{type: :user, id: @reviewer}]}
  def exclusions(_specs, _ctx), do: {:ok, []}
  def escalate(_task, _ctx), do: :ok

  def reviewer, do: @reviewer
end
