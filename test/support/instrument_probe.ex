# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.InstrumentProbe do
  @moduledoc """
  The four answer kinds, as generic actions, for the instrument contract
  suite (`mix test --only instrument_contract`).

  A resource with **no data layer**, because there is nothing to store —
  the same shape ash_enterprise uses for its prompt-backed classifier. The
  actions return upstream's answer types (wrapped in `AshAi.Actions.Result`
  so the suite records which model answered), and the model comes from the
  profile under test through the context, mirroring the clinic-demo spike's
  resolver: the context names the profile, resolution fails loud instead of
  silently falling back — a contract result must never lie about which
  instrument answered it.
  """

  use Ash.Resource,
    domain: AshJudgments.Test.Domain,
    extensions: [AshAi],
    data_layer: Ash.DataLayer.Simple

  actions do
    action :noul, AshAi.Actions.Result do
      description "Does the text describe a fall? (contract probe)"
      argument :text, :string, allow_nil?: false
      constraints of: AshAi.Evaluate.Noul

      run {AshJudgments.Test.InstrumentProbe.Evaluate, model: &__MODULE__.resolve_model/2}
    end

    action :choice, AshAi.Actions.Result do
      description "Which disposition does the text support? (contract probe)"

      argument :text, :string, allow_nil?: false

      constraints of: AshAi.Evaluate.Choice,
                  constraints: [of: AshJudgments.Test.Disposition]

      run {AshJudgments.Test.InstrumentProbe.Evaluate, model: &__MODULE__.resolve_model/2}
    end

    action :score, AshAi.Actions.Result do
      description "How urgent is this text? (contract probe)"

      argument :text, :string, allow_nil?: false

      constraints of: AshAi.Evaluate.Score,
                  constraints: [levels: ["Routine", "Time-sensitive", "Urgent"]]

      run {AshJudgments.Test.InstrumentProbe.Evaluate, model: &__MODULE__.resolve_model/2}
    end

    action :judgments, AshAi.Actions.Result do
      description "Two-at-once contract probe over the same state."

      argument :text, :string, allow_nil?: false

      constraints of: AshAi.Evaluate.Judgments,
                  constraints: [
                    fields: [
                      fall: [
                        type: AshAi.Evaluate.Noul,
                        description: "Does the text describe a fall?"
                      ],
                      disposition: [
                        type: AshAi.Evaluate.Choice,
                        description: "Which disposition does the text support?",
                        constraints: [of: AshJudgments.Test.Disposition]
                      ]
                    ]
                  ]

      run {AshJudgments.Test.InstrumentProbe.Evaluate, model: &__MODULE__.resolve_model/2}
    end
  end

  @doc """
  The model resolver `evaluate` calls. The profile rides the action
  context (`input.context[:instrument_probe][:profile]` — the same
  context-carrying shape the clinic-demo spike resolves from); no
  context, no probe — raising beats guessing, because a guessed
  instrument would make the contract result a lie about what it tested.
  """
  def resolve_model(input, _action_context) do
    case get_in(input.context, [:instrument_probe, :profile]) do
      %AshJudgments.Profile{} = profile ->
        case AshJudgments.Profile.model_spec(profile, %{}, input.context) do
          {:ok, spec} -> spec
          {:error, exception} -> raise exception
        end

      _ ->
        raise ArgumentError,
              "instrument probe actions need context: %{instrument_probe: %{profile: profile}}"
    end
  end

  defmodule Evaluate do
    @moduledoc """
    Upstream's evaluate implementation, with the profile's transport opts
    (`AshJudgments.Profile.req_llm_opts/1`) computed from the context and
    passed through as `req_llm_opts`. Test plumbing only: the call itself
    is upstream's `AshAi.Actions.Evaluate.run/3`, unmodified — local
    profiles need runtime-computed transport (a `{:system, var}` base_url
    resolves per call), and upstream's `req_llm_opts` is a compile-time
    action option.
    """

    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, opts, context) do
      opts =
        case get_in(input.context, [:instrument_probe, :profile]) do
          %AshJudgments.Profile{} = profile ->
            {:ok, computed} = AshJudgments.Profile.req_llm_opts(profile)
            Keyword.update(opts, :req_llm_opts, computed, &(&1 ++ computed))

          _ ->
            opts
        end

      AshAi.Actions.Evaluate.run(input, opts, context)
    end
  end
end
