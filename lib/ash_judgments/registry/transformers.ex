# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Transformers do
  @moduledoc """
  Derives identity and generates the judge actions.

  For each declared question, at compile time:

  - **options** are resolved — Noul `[true, false]`, Score the declared
    `levels:`, Choice the `of` enum/list or `options_from {Resource,
    :attribute}` (the attribute's `one_of` or `Ash.Type.Enum` values — the
    same constraint that validates the attribute), with the abstain option
    appended for Choice (law 7: abstention is first-class);
  - **`state_contract`** is the digest of the projection's DECLARED
    output shape (the `state_shape` option), or `nil` when none is
    declared (the digest of nothing is `nil`, never the digest of `%{}`);
  - **`question_hash`** is the RFC §3.2 digest over the canonical JSON of
    exactly the identity object;
  - **`question_id`** is the §3.1 structural id
    `judgment:v0:<Module>#judgments/<name>`;
  - the **`judge_<name>`** and **`judge_<name>_matrix`** generic actions
    are generated, and an ash_ai `tool` for questions declaring
    `expose_as_tool? true` (read-only by construction).
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  alias AshJudgments.Registry.Canonical

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    with {:ok, dsl_state, questions} <- build_identity(dsl_state, module) do
      {:ok, questions}
      |> generate_actions(dsl_state, module)
      |> generate_tools(dsl_state, module)
      |> persist_questions()
    end
  end

  ## Identity

  defp build_identity(dsl_state, module) do
    dsl_state
    |> Transformer.get_entities([:judgments])
    |> Enum.reduce_while({:ok, dsl_state, []}, fn question, {:ok, dsl, built} ->
      case derive_identity(question, module, dsl_state) do
        {:ok, question} ->
          dsl =
            Transformer.replace_entity(dsl, [:judgments], question, &(&1.name == question.name))

          {:cont, {:ok, dsl, [question | built]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, dsl, built} -> {:ok, dsl, Enum.reverse(built)}
      {:error, error} -> {:error, error}
    end
  end

  defp derive_identity(question, module, dsl_state) do
    with {:ok, options} <- resolve_options(question, module, dsl_state) do
      state_contract = Canonical.state_contract(question.state_shape)
      declare_external_resource(module)

      question =
        question
        |> Map.put(:options, options)
        |> Map.put(:state_contract, state_contract)
        |> Map.put(
          :question_hash,
          Canonical.question_hash(%{
            answer_type: question.type,
            criteria: question.criteria,
            instructions: question.instructions,
            options: options,
            state_contract: state_contract,
            version: question.version
          })
        )
        |> Map.put(:question_id, Canonical.question_id(module, question.name))

      {:ok, question}
    end
  end

  # The lock file feeds a compile-time check on this module's questions, so
  # editing it must recompile them (the `ash.codegen --check` contract).
  # Registered here rather than in the verifier: the module body is still
  # open while transformers run.
  defp declare_external_resource(module) do
    path = AshJudgments.Registry.Verifiers.VerifyLock.lock_path()

    if File.exists?(path) and function_exported?(Module, :put_attribute, 3) do
      Module.put_attribute(module, :external_resource, path)
    end

    :ok
  rescue
    # A module that is not the one being compiled (e.g. re-deriving identity
    # outside compilation) cannot take attributes; the lock check still runs,
    # only the recompile hook is absent.
    _ -> :ok
  end

  defp resolve_options(%{type: AshAi.Evaluate.Noul}, _module, _dsl_state),
    do: {:ok, [true, false]}

  defp resolve_options(%{type: AshAi.Evaluate.Score} = question, module, _dsl_state) do
    case question.constraints[:levels] do
      [_ | _] = levels ->
        {:ok, levels}

      _ ->
        {:error,
         dsl_error(
           module,
           question.name,
           :constraints,
           "a Score question needs `constraints levels:` (the ordered level list)"
         )}
    end
  end

  defp resolve_options(%{type: AshAi.Evaluate.Choice} = question, module, dsl_state) do
    with {:ok, source_options} <- choice_source_options(question, module, dsl_state) do
      {:ok, source_options ++ [question.abstain_option]}
    end
  end

  defp choice_source_options(question, module, dsl_state) do
    cond do
      question.options_from ->
        options_from_attribute(question, module, dsl_state)

      of = question.constraints[:of] ->
        of_options(of)

      true ->
        {:error,
         dsl_error(
           module,
           question.name,
           :constraints,
           "a Choice question needs `options_from {Resource, :attribute}` or `constraints of:` (the option list or an Ash.Type.Enum)"
         )}
    end
  end

  defp of_options(of) when is_atom(of) do
    cond do
      function_exported?(of, :values, 0) ->
        # Ash.Type.Enum
        {:ok, of.values()}

      function_exported?(of, :schema, 0) ->
        # An Ash.NewType wrapping one_of
        case of.type_constraints([], [])[:one_of] do
          [_ | _] = values -> {:ok, values}
          _ -> {:error, "the type #{inspect(of)} declares no one_of options"}
        end

      true ->
        {:error, "#{inspect(of)} is neither an Ash.Type.Enum nor a type with one_of constraints"}
    end
  rescue
    _ -> {:error, "could not derive options from #{inspect(of)}"}
  end

  defp of_options(of) when is_list(of), do: {:ok, of}

  defp of_options(of),
    do:
      {:error,
       "`of` must be an Ash.Type.Enum, a one_of NewType or a plain list, got #{inspect(of)}"}

  defp options_from_attribute(question, module, dsl_state) do
    {resource, attribute_name} = question.options_from

    # The declaring resource is still being compiled — its attributes
    # live in the DSL state, not behind its Info module yet.
    attribute =
      if resource == module do
        dsl_state
        |> Transformer.get_entities([:attributes])
        |> Enum.find(&(&1.name == attribute_name))
      else
        resource |> Ash.Resource.Info.attributes() |> Enum.find(&(&1.name == attribute_name))
      end

    cond do
      is_nil(attribute) ->
        {:error,
         dsl_error(
           module,
           question.name,
           :options_from,
           "the source #{inspect(resource)} has no attribute #{inspect(attribute_name)}"
         )}

      attribute.constraints[:one_of] ->
        {:ok, attribute.constraints[:one_of]}

      enum_values(attribute.type) ->
        {:ok, enum_values(attribute.type)}

      true ->
        {:error,
         dsl_error(
           module,
           question.name,
           :options_from,
           "the source attribute #{inspect(resource)}.#{attribute_name} declares neither one_of nor an Ash.Type.Enum"
         )}
    end
  end

  defp enum_values(type) do
    Code.ensure_loaded!(type)

    if function_exported?(type, :values, 0) do
      type.values()
    end
  end

  ## Generated actions

  defp generate_actions({:ok, questions}, dsl_state, _module) when questions == [] do
    {:ok, questions, dsl_state}
  end

  defp generate_actions({:ok, questions}, dsl_state, _module) do
    Enum.reduce_while(questions, {:ok, questions, dsl_state}, fn question, {:ok, qs, dsl} ->
      with {:ok, judge} <- build_judge_action(question),
           {:ok, matrix} <- build_matrix_action(question) do
        dsl =
          dsl
          |> Transformer.add_entity([:actions], judge)
          |> Transformer.add_entity([:actions], matrix)

        {:cont, {:ok, qs, dsl}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp build_judge_action(question) do
    Builder.build_action(:action, judge_name(question),
      description: question_description(question),
      returns: question.type,
      constraints: return_constraints(question),
      arguments: [
        Builder.build_action_argument(:input, :map, allow_nil?: false, public?: true)
      ],
      run: {AshJudgments.Registry.Judge, [question: question.name]}
    )
  end

  defp build_matrix_action(question) do
    Builder.build_action(:action, matrix_name(question),
      description:
        question_description(question) <> " (matrix: one judged answer per runtime question)",
      returns: {:array, question.type},
      constraints: [items: return_constraints(question)],
      arguments: [
        Builder.build_action_argument(:input, :map, allow_nil?: false, public?: true),
        Builder.build_action_argument(:questions, {:array, :map},
          allow_nil?: false,
          public?: true,
          description:
            "One runtime question per element: a map with `instructions` (and optional `criteria`), answered in order"
        )
      ],
      run: {AshJudgments.Registry.Judge, [question: question.name, matrix?: true]}
    )
  end

  # Compile-time atom construction from DSL-declared names (a bounded,
  # host-authored set — the law 10 exception for compile-time constants,
  # written in the literal form that says so).
  # Action-return constraints for the answer types that carry them: a
  # Score's ordered levels (they are part of the cast contract) and a
  # Choice's `of` when it names an Ash.Type.Enum (a plain runtime option
  # list rides the questions' criteria instead).
  defp return_constraints(%{
         type: AshAi.Evaluate.Score,
         constraints: %{levels: [_ | _] = levels}
       }),
       do: [levels: levels]

  defp return_constraints(%{type: AshAi.Evaluate.Choice, constraints: %{of: of}})
       when is_atom(of),
       do: [of: of]

  defp return_constraints(_), do: []

  defp judge_name(question), do: :"judge_#{question.name}"
  defp matrix_name(question), do: :"judge_#{question.name}_matrix"

  defp question_description(%{instructions: instructions}) when is_binary(instructions),
    do: instructions

  defp question_description(question),
    do: "Judged question #{question.name} (family #{question.family})"

  ## Generated tools (ash_ai)

  defp generate_tools({:ok, questions, dsl_state}, _dsl, _module) do
    tools =
      questions
      |> Enum.filter(& &1.expose_as_tool?)
      |> Enum.map(fn question ->
        struct(AshAi.Tool,
          name: judge_name(question),
          action: judge_name(question),
          description: question_description(question)
        )
      end)

    dsl_state =
      Enum.reduce(tools, dsl_state, fn tool, dsl ->
        Transformer.add_entity(dsl, [:tools], tool)
      end)

    {:ok, questions, dsl_state}
  end

  ## Persistence

  defp persist_questions({:ok, questions, dsl_state}) do
    {:ok, Transformer.persist(dsl_state, :questions, questions)}
  end

  defp dsl_error(module, question_name, field, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:judgments, question_name, field],
      message: message
    )
  end
end
