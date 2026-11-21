# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Explain do
  @moduledoc """
  Where a materialised fact came from, on the `ash_provenance` contract.

  The chain for an automated admission runs fact, banding (the band table that decided), the decision evaluation (which
  rules matched), the judgment observations the table read, and the atoms those observations cited:

      fact --was_generated_by--> banding --used--> decision evaluation
                                    \\--was_derived_from--> observation --was_derived_from--> atom

  `fact/3` builds that chain from records the caller has already read. It reads nothing itself, so the caller's actor,
  tenant and field policies decide what is passed in, and the explainer never widens them.

  ## What each link may be

  Every record in `links` is one of:

    * the record itself;
    * `:unreadable`, when the reader may not see it: the answer is a `:unreadable` gap that carries no identifier;
    * `nil`, when the row is not there: the answer is a `:not_recorded` gap.

  A `:person` fact is the answer by itself: a person entered it, and `admission_id` is the host's own reference, which
  this package does not resolve. A fact with no `admission_id` has no recorded decision behind it and reads
  `:not_recorded`. That is how a fact written by `AshJudgments.Facts.Replay` from a payload that carried no
  `admission_id` reads, since a replay re-materialises recorded decisions and never re-evaluates one.

  ## Matched rules

  The decision evaluation's `matched_rule_ids`, `hit_policy`, `error` and recording time are classified by
  `AshProvenance.MatchedRules`: matched rules are named; an empty list with a hit policy is a real "no rule matched";
  an error is a `:failed` gap; no hit policy, or a row from before rule ids were recorded, is `:not_recorded`. The
  evaluation's `error` is never copied into the answer.

  ## Options

    * `:base` - the address base, an absolute http(s) URI. Required.
    * `:types` - overrides for the address type tokens. Keys `:fact`, `:banding`, `:observation`, `:evaluation`,
      `:atom`; defaults `"fact"`, `"banding"`, `"judgment_observation"`, `"decision_evaluation"`, `"addressed_atom"`.
    * `:atoms` - `(observation_address, atom_ids -> %{steps: [...], gaps: [...]})`, for example
      `&AshEvidence.Explanation.provenance(&1, &2, actor: actor)`. Without it each cited atom is one plain
      `:was_derived_from` step, which says what the observation cited and not whether the atom still exists.
    * `:max_steps` - the step cap, default 200. A longer chain is cut and says so in `bounds`.
  """

  @moduledoc since: "0.4.0"

  alias AshProvenance.{Address, Explanation, Gap, MatchedRules, Plan, Step}

  @types %{
    fact: "fact",
    banding: "banding",
    observation: "judgment_observation",
    evaluation: "decision_evaluation",
    atom: "addressed_atom"
  }
  @max_depth 3
  @default_max_steps 200
  @rules_budget 120

  @type link :: struct() | map() | :unreadable | nil
  @type links :: %{
          optional(:banding) => link(),
          optional(:evaluation) => link(),
          optional(:observations) => [map()] | :unreadable | nil
        }

  @doc """
  Explains `fact` (its `value`) from the records in `links`: `:banding`, `:evaluation` (the banding's
  `decision_evaluation_id`) and `:observations` (the banding's `observation_ids`).
  """
  @spec fact(map(), links(), keyword()) :: {:ok, Explanation.t()} | {:error, term()}
  def fact(fact, links \\ %{}, opts) do
    ctx = %{
      base: Keyword.fetch!(opts, :base),
      types: Map.merge(@types, Map.new(opts[:types] || [])),
      atoms: opts[:atoms] || (&plain_atoms/2)
    }

    subject =
      Address.new!(
        base: ctx.base,
        type: ctx.types.fact,
        id: to_string(fact.id),
        attribute: "value"
      )

    {steps, gaps, depth} = walk(fact, subject, links, ctx)

    max_steps = opts[:max_steps] || @default_max_steps
    kept = Enum.take(steps, max_steps)

    Explanation.new(
      subject: subject,
      steps: kept,
      gaps: gaps,
      bounds: %{
        max_depth: @max_depth,
        max_steps: max_steps,
        depth: depth,
        step_count: length(kept),
        cut?: length(kept) < length(steps)
      }
    )
  end

  defp walk(%{admission_id: nil}, subject, _links, _ctx) do
    {[], [gap(:not_recorded, subject, "no admission is recorded for this fact")], 0}
  end

  defp walk(%{admission_grade: :person}, subject, _links, _ctx) do
    step =
      Step.new!(
        relation: :was_attributed_to,
        entity: subject,
        agent_label: "a person",
        granularity: :value,
        summary: "entered or confirmed by a person"
      )

    {[step], [], 1}
  end

  defp walk(fact, subject, links, ctx) do
    case banding_link(fact, Map.get(links, :banding)) do
      {:ok, banding} ->
        banding_address = address(ctx, :banding, banding.id)
        {fact_steps, plan} = fact_step(subject, banding, banding_address)

        {decision_steps, decision_gaps} =
          decision(subject, banding, banding_address, links, plan, ctx)

        {obs_steps, obs_gaps, obs_depth} =
          observations(subject, banding, banding_address, links, ctx)

        {fact_steps ++ decision_steps ++ obs_steps, decision_gaps ++ obs_gaps, max(2, obs_depth)}

      {:gap, gap_fun} ->
        {[], [gap_fun.(subject)], 0}
    end
  end

  defp banding_link(_fact, :unreadable), do: {:gap, &Gap.new!(kind: :unreadable, of: &1)}

  defp banding_link(%{admission_id: id}, %{id: id} = banding), do: {:ok, banding}

  defp banding_link(_fact, _other) do
    {:gap, &gap(:not_recorded, &1, "the banding behind this admission is not available")}
  end

  defp fact_step(subject, banding, banding_address) do
    table = Map.get(banding, :band_table) || %{}

    plan =
      plan(
        field(table, :definition_key),
        field(table, :definition_version),
        field(table, :content_hash)
      )

    step =
      Step.new!(
        relation: :was_generated_by,
        entity: subject,
        activity: Address.to_trace_ref(banding_address),
        plan: plan,
        at: Map.get(banding, :banded_at),
        execution_context: Map.get(banding, :mode),
        granularity: :value,
        summary: banding_summary(banding)
      )

    {[step], plan}
  end

  defp banding_summary(banding) do
    clip(
      "band #{Map.get(banding, :band)}" <>
        reason(Map.get(banding, :reason_code)) <>
        "; rules " <> rules(Map.get(banding, :matched_rule_ids) || [])
    )
  end

  defp reason(nil), do: ""
  defp reason(code), do: " (#{code})"

  defp decision(subject, banding, banding_address, links, plan, ctx) do
    case Map.get(links, :evaluation) do
      :unreadable ->
        {[], [Gap.new!(kind: :unreadable, of: subject)]}

      %{id: id} = evaluation when id == banding.decision_evaluation_id ->
        evaluation_steps(subject, banding_address, evaluation, plan, ctx)

      _missing ->
        {[],
         [
           gap(
             :not_recorded,
             subject,
             "the decision evaluation behind this banding is not available"
           )
         ]}
    end
  end

  defp evaluation_steps(subject, banding_address, evaluation, banding_plan, ctx) do
    ids = Map.get(evaluation, :matched_rule_ids) || []
    hit_policy = Map.get(evaluation, :hit_policy)

    result =
      MatchedRules.classify(
        ids,
        hit_policy,
        Map.get(evaluation, :error),
        Map.get(evaluation, :inserted_at)
      )

    step =
      Step.new!(
        relation: :used,
        entity: address(ctx, :evaluation, evaluation.id),
        activity: Address.to_trace_ref(banding_address),
        plan:
          plan(
            Map.get(evaluation, :definition_key),
            Map.get(evaluation, :definition_version),
            nil
          ) || banding_plan,
        at: Map.get(evaluation, :inserted_at),
        granularity: :record,
        summary: clip(evaluation_summary(result, hit_policy))
      )

    {[step], evaluation_gaps(result, subject)}
  end

  defp evaluation_summary({:matched, ids}, hit_policy),
    do: "rules matched: #{rules(ids)}" <> policy(hit_policy)

  defp evaluation_summary(:no_rule_matched, hit_policy),
    do: "no rule matched" <> policy(hit_policy)

  defp evaluation_summary({:gap, :failed}, _), do: "the evaluation failed"
  defp evaluation_summary({:gap, :not_recorded}, _), do: "the matched rules were not recorded"

  defp policy(nil), do: ""
  defp policy(hit_policy), do: " (hit policy #{hit_policy})"

  defp evaluation_gaps({:gap, :failed}, subject),
    do: [gap(:failed, subject, "the decision evaluation failed")]

  defp evaluation_gaps({:gap, :not_recorded}, subject),
    do: [gap(:not_recorded, subject, "the matched rules were not recorded for this evaluation")]

  defp evaluation_gaps(_answered, _subject), do: []

  defp observations(subject, banding, banding_address, links, ctx) do
    ids = Map.get(banding, :observation_ids) || []

    case Map.get(links, :observations) do
      :unreadable ->
        {[], Enum.map(ids, fn _ -> Gap.new!(kind: :unreadable, of: subject) end), 2}

      found ->
        by_id = Map.new(found || [], &{&1.id, &1})

        {steps, gaps, depth} =
          Enum.reduce(
            ids,
            {[], [], 2},
            &observation_hop(&1, by_id, subject, banding_address, ctx, &2)
          )

        {steps |> Enum.reverse() |> List.flatten(), gaps |> Enum.reverse() |> List.flatten(),
         depth}
    end
  end

  defp observation_hop(id, by_id, subject, banding_address, ctx, {steps, gaps, depth}) do
    case Map.fetch(by_id, id) do
      {:ok, observation} ->
        {obs_steps, obs_gaps} = observation_steps(banding_address, observation, ctx)
        {[obs_steps | steps], [obs_gaps | gaps], max(depth, depth_of(observation))}

      :error ->
        gap = gap(:not_recorded, subject, "an observation behind this banding is not available")
        {steps, [[gap] | gaps], depth}
    end
  end

  defp depth_of(observation),
    do: if((Map.get(observation, :atom_ids) || []) == [], do: 2, else: 3)

  defp observation_steps(banding_address, observation, ctx) do
    address = address(ctx, :observation, observation.id)

    step =
      Step.new!(
        relation: :was_derived_from,
        entity: banding_address,
        antecedent: address,
        plan:
          plan(
            Map.get(observation, :question_id),
            Map.get(observation, :question_version),
            Map.get(observation, :question_hash)
          ),
        execution_context: Map.get(observation, :mode),
        granularity: :record,
        summary:
          clip(
            "#{Map.get(observation, :answer_kind)} answer to #{Map.get(observation, :question_id)}"
          )
      )

    atoms = ctx.atoms.(address, Map.get(observation, :atom_ids) || [])
    {[step | atoms.steps], atoms.gaps}
  end

  defp plain_atoms(observation_address, atom_ids) do
    steps =
      Enum.map(atom_ids, fn id ->
        Step.new!(
          relation: :was_derived_from,
          entity: observation_address,
          antecedent:
            Address.new!(base: observation_address.base, type: @types.atom, id: to_string(id)),
          granularity: :record
        )
      end)

    %{steps: steps, gaps: []}
  end

  defp address(ctx, kind, id),
    do: Address.new!(base: ctx.base, type: Map.fetch!(ctx.types, kind), id: to_string(id))

  defp gap(kind, of, summary), do: Gap.new!(kind: kind, of: of, summary: summary)

  defp plan(key, version, hash) when is_binary(key) and not is_nil(version) do
    case Plan.new(key: key, version: to_string(version), hash8: hash8(hash)) do
      {:ok, plan} -> plan
      {:error, _} -> nil
    end
  end

  defp plan(_key, _version, _hash), do: nil

  defp hash8(hash) when is_binary(hash) do
    hex = hash |> String.replace_prefix("sha256:", "") |> String.downcase()
    if Regex.match?(~r/\A[0-9a-f]{8}/, hex), do: String.slice(hex, 0, 8)
  end

  defp hash8(_), do: nil

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp rules([]), do: "none"

  # Rule ids are listed while they fit the budget, so the count of the rest survives the summary's byte cap.
  defp rules(ids) do
    {shown, rest} = take_within(ids, @rules_budget, [])
    Enum.join(shown, ", ") <> if(rest == [], do: "", else: " (+#{length(rest)} more)")
  end

  defp take_within([id | rest], budget, [] = acc),
    do: take_within(rest, budget - byte_size(id), [id | acc])

  defp take_within([id | rest] = ids, budget, acc) do
    if byte_size(id) + 2 <= budget,
      do: take_within(rest, budget - byte_size(id) - 2, [id | acc]),
      else: {Enum.reverse(acc), ids}
  end

  defp take_within([], _budget, acc), do: {Enum.reverse(acc), []}

  defp clip(text) when byte_size(text) <= 280, do: text
  defp clip(text), do: text |> String.slice(0, String.length(text) - 1) |> clip()
end
