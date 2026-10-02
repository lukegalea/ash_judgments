# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Judge.Signals do
  @moduledoc """
  The implementation behind every generated `judge_<name>_signals` action
  (the `bpmn_callable? true` option, AST-94).

  It runs the SAME judge path as `judge_<name>` - same state projection,
  same profile resolution, same recorder - and shapes the result into the
  STRING-KEYED, SCALAR-VALUED map a BPMN `ash:call` may promote onto a
  token: the answer's scalars plus the judgment id, the observation id
  that joins the token back to the full ledger row.

  **The scalar-promotion discipline** (AST-94): answer structs never
  promote onto a token. No map-of-structs, no dotted paths - a gateway
  that cannot read an answer struct is the reason this shape exists.

  ## Actor discipline ([L]4)

  The signals action runs as whoever calls it: the requesting actor's
  context passes through to the recorder unchanged, and the package
  injects NO default actor. Engine-originated judgments therefore carry
  the engine's caller - where a process runs unattended, the host wires
  its own automation principal and grant_ref per [L]4 (host policy
  posture, asserted in the bridge tests where the package can speak).
  """

  use Ash.Resource.Actions.Implementation

  alias AshJudgments.Bridge.Bpmn
  alias AshJudgments.Registry.Info

  @impl true
  def run(input, opts, context) do
    question =
      Info.questions(input.resource) |> Enum.find(&(&1.name == Keyword.fetch!(opts, :question)))

    question_key = Atom.to_string(question.name)

    # The judge path runs against the question's own judge action — its
    # `returns` is the answer type upstream `AshAi.Actions.Evaluate`
    # plans against (the signals action's map return is the SHAPE of the
    # result, not the answer's). The context carries through unchanged —
    # actor and tenant ride in it — so the engine's caller is the
    # judgment's actor ([L]4).
    # The literal `:"..."` form over the registry's own declared name —
    # the same naming convention the transformer generated the action with.
    judge_action = :"judge_#{question.name}"

    judge_input =
      input.resource
      |> Ash.ActionInput.for_action(judge_action, %{
        "input" => Ash.ActionInput.get_argument(input, :input)
      })
      |> Map.replace!(:tenant, input.tenant)
      |> Map.replace!(:context, input.context)

    case AshJudgments.Registry.Judge.judge_and_record(
           question,
           judge_input,
           input.context,
           context,
           opts
         ) do
      {:ok, answer, judgment_ids} ->
        judgment_id = List.first(judgment_ids)
        {:ok, Bpmn.signal_map(question_key, question, answer, judgment_id)}

      {:error, error, _partial} ->
        {:error, error}
    end
  end
end
