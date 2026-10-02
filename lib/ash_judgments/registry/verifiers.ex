# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Registry.Verifiers.VerifyPiiProjection do
  @moduledoc """
  `pii: :minimised` implies a `state_projection` (CORE-REGISTRY/AC-4).

  Declaring that personal data is minimised without declaring the
  projection that minimises it is a contradiction the compiler refuses:
  without a projection, upstream's default state is the whole argument
  map, which is exactly what `:minimised` promises not to send.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Transformer

  @impl true
  def verify(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Transformer.get_entities([:judgments])
      |> Enum.filter(&(&1.pii == :minimised and is_nil(&1.state_projection)))
      |> Enum.map(fn question ->
        Spark.Error.DslError.exception(
          module: module,
          path: [:judgments, question.name, :pii],
          message:
            "pii: :minimised requires a state_projection (a module implementing project/2 or an MFA); without one the default state is the whole action input"
        )
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end

defmodule AshJudgments.Registry.Verifiers.VerifyRecordPin do
  @moduledoc """
  `record: :must` implies `pin: :required` (law 6).

  A must-record family feeds admitted facts, and a fact's verdict is a
  function of the model digest: a floating instrument in a must-record
  family is a silent policy change. The transformer defaults `pin` to
  `:required` for `record: :must`; this verifier refuses the explicit
  contradiction (`record: :must, pin: :optional`).
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Transformer

  @impl true
  def verify(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Transformer.get_entities([:judgments])
      |> Enum.filter(&(&1.record == :must and &1.pin == :optional))
      |> Enum.map(fn question ->
        Spark.Error.DslError.exception(
          module: module,
          path: [:judgments, question.name, :pin],
          message:
            "record: :must implies pin: :required (law 6); a must-record family cannot ride a floating instrument. Use record: :best_effort for tooling families"
        )
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end

defmodule AshJudgments.Registry.Verifiers.VerifyFamily do
  @moduledoc """
  A question declares its family (law 5).

  The family is the calibration grouping: a band table may not publish
  for a family without a calibration run above a minimum n, so a question
  without a family could never earn a threshold. The schema marks `family`
  required; this verifier is the friendly form of that error and guards
  the programmatic path.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Transformer

  @impl true
  def verify(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Transformer.get_entities([:judgments])
      |> Enum.filter(&(is_nil(&1.family) or not is_atom(&1.family)))
      |> Enum.map(fn question ->
        Spark.Error.DslError.exception(
          module: module,
          path: [:judgments, question.name, :family],
          message:
            "a question must declare its family (an atom) — the calibration grouping of law 5"
        )
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end

defmodule AshJudgments.Registry.Verifiers.VerifyOptionsSubset do
  @moduledoc """
  Explicit Choice options are a subset of the source constraint.

  When a question both derives options (`options_from {Resource,
  :attribute}`) and declares explicit `constraints of:` (a plain list),
  the explicit list must be a subset of the source values: the model may
  only ever choose what the attribute's own constraint admits, or a
  judged answer could be an option the subject cannot legally hold.
  """

  @moduledoc since: "0.1.0"

  use Spark.Dsl.Verifier
  alias Spark.Dsl.Transformer

  @impl true
  def verify(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    errors =
      dsl_state
      |> Transformer.get_entities([:judgments])
      |> Enum.flat_map(&subset_errors(&1, module))

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp subset_errors(question, module) do
    explicit = question.constraints[:of]

    with true <- question.options_from != nil,
         true <- is_list(explicit),
         {resource, attribute_name} <- question.options_from,
         overflow <- overflow(question, resource, attribute_name, explicit) do
      if overflow == [] do
        []
      else
        [
          Spark.Error.DslError.exception(
            module: module,
            path: [:judgments, question.name, :constraints],
            message:
              "explicit options #{inspect(overflow)} are not in the source constraint " <>
                "#{inspect(resource)}.#{attribute_name} (#{inspect(source_values_for(resource, attribute_name))}); " <>
                "the model may only choose what the attribute admits"
          )
        ]
      end
    else
      _ -> []
    end
  end

  defp overflow(_question, resource, attribute_name, explicit) do
    attribute =
      Enum.find(Ash.Resource.Info.attributes(resource), &(&1.name == attribute_name))

    source = source_values(attribute)
    Enum.reject(explicit, &(&1 in source))
  end

  defp source_values_for(resource, attribute_name) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.find(&(&1.name == attribute_name))
    |> source_values()
  end

  defp source_values(%{constraints: %{one_of: one_of}}) when is_list(one_of), do: one_of

  defp source_values(%{type: type}) when is_atom(type) do
    Code.ensure_loaded!(type)

    if function_exported?(type, :values, 0), do: type.values(), else: []
  end

  defp source_values(_), do: []
end
