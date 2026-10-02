# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.ExtractionTest do
  @moduledoc """
  The extraction answer type: scalar and composite round-trips, the
  status semantics (value non-nil iff found), the refusal paths
  (reject, never repair), identity ([L]2: value schema in criteria,
  options = the status enum), the narrowed wire schema, the record
  wiring (kind/atom_ids/value), and the registry declaration contract.
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  alias AshJudgments.Evaluate.Extraction
  alias AshJudgments.Registry.Canonical

  @obs "eeeeeeee-1111-4111-8111-111111111111"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_facts test_bandings test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)
    put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :ledger)
      Application.put_env(:ash_judgments, :region, :ca)
    end)

    :ok
  end

  defp q(constraints) do
    %{name: :probe, type: Extraction, constraints: constraints}
  end

  # from_answer returns the plain map the behaviour's contract carries
  # (upstream casts it into the answer struct); the struct round-trip is
  # asserted once here and the maps below feed it.
  test "from_answer's map casts into the answer struct" do
    {:ok, map} =
      Extraction.from_answer(
        %{"value" => "urgent", "status" => "found", "source_ids" => ["a01"]},
        of: :string
      )

    assert %Extraction{} = struct!(Extraction, map)
  end

  describe "round-trips (cast through the declared type)" do
    test "a string value" do
      assert {:ok, %{status: :found, value: "urgent", source_ids: ["a01"]}} =
               Extraction.from_answer(
                 %{"value" => "urgent", "status" => "found", "source_ids" => ["a01"]},
                 of: :string
               )
    end

    test "a boolean value" do
      assert {:ok, %{value: true}} =
               Extraction.from_answer(
                 %{"value" => true, "status" => "found", "source_ids" => []},
                 of: :boolean
               )
    end

    test "an integer value" do
      assert {:ok, %{value: 80}} =
               Extraction.from_answer(
                 %{"value" => 80, "status" => "found", "source_ids" => []},
                 of: :integer
               )
    end

    test "a decimal value" do
      assert {:ok, %{value: %Decimal{} = value}} =
               Extraction.from_answer(
                 %{"value" => "80.5", "status" => "found", "source_ids" => []},
                 of: :decimal
               )

      assert Decimal.eq?(value, "80.5")
    end

    test "a composite map value (one typed value, one status)" do
      value = %{"from" => "2027-01-01", "to" => "2027-03-31"}

      assert {:ok, %{value: ^value}} =
               Extraction.from_answer(
                 %{"value" => value, "status" => "found", "source_ids" => []},
                 of: :map
               )
    end

    test "a value against inner constraints (an enum atom)" do
      assert {:ok, %{value: :high}} =
               Extraction.from_answer(
                 %{"value" => "high", "status" => "found", "source_ids" => []},
                 of: :atom,
                 constraints: [one_of: [:low, :high]]
               )

      assert {:error, _} =
               Extraction.from_answer(
                 %{"value" => "medium", "status" => "found", "source_ids" => []},
                 of: :atom,
                 constraints: [one_of: [:low, :high]]
               )
    end
  end

  describe "status semantics (value non-nil iff found)" do
    test "found with a nil value is refused" do
      assert {:error, error} =
               Extraction.from_answer(
                 %{"value" => nil, "status" => "found", "source_ids" => []},
                 of: :string
               )

      assert error =~ "a found extraction carries its value"
    end

    test "not_found and ambiguous refuse a value — reject, never repair" do
      for status <- ["not_found", "ambiguous"] do
        assert {:error, error} =
                 Extraction.from_answer(
                   %{"value" => "2027-03-31", "status" => status, "source_ids" => []},
                   of: :string
                 )

        assert error =~ "never repair"
      end

      for status <- ["not_found", "ambiguous"] do
        assert {:ok, %{value: nil}} =
                 Extraction.from_answer(
                   %{"value" => nil, "status" => status, "source_ids" => []},
                   of: :string
                 )
      end
    end

    test "a status outside the vocabulary is refused" do
      assert {:error, error} =
               Extraction.from_answer(
                 %{"value" => "x", "status" => "probably", "source_ids" => []},
                 of: :string
               )

      assert error =~ "outside the vocabulary"
    end

    test "a shape that is not an extraction answer is refused" do
      assert {:error, _} = Extraction.from_answer(%{"probability" => 0.5}, of: :string)
      assert {:error, _} = Extraction.from_answer("found", of: :string)
    end
  end

  describe "source ids (the fabricated-citation guard)" do
    test "ids outside the narrowed enum are refused" do
      assert {:error, error} =
               Extraction.from_answer(
                 %{"value" => "x", "status" => "found", "source_ids" => ["a01", "fabricated"]},
                 of: :string,
                 source_enum: ["a01", "a02"]
               )

      assert error =~ "outside the packet's enum"
      assert error =~ "fabricated"
    end

    test "ids inside the enum pass; no enum admits anything" do
      assert {:ok, _} =
               Extraction.from_answer(
                 %{"value" => "x", "status" => "found", "source_ids" => ["a01"]},
                 of: :string,
                 source_enum: ["a01", "a02"]
               )

      assert {:ok, _} =
               Extraction.from_answer(
                 %{"value" => "x", "status" => "found", "source_ids" => ["anything"]},
                 of: :string
               )
    end
  end

  describe "identity ([L]2) and the wire schema" do
    test "to_question puts the declared value schema in criteria, hashed verbatim" do
      assert {:ok, question} = Extraction.to_question("extract the deadline", nil, of: :date)
      assert question.type == :extraction
      assert question.criteria == %{"type" => "string", "format" => "date"}

      # The criteria ride the question hash verbatim: the same declaration
      # hashes identically, a changed value schema mints a new hash.
      a =
        Canonical.question_hash(%{
          answer_type: Extraction,
          criteria: question.criteria,
          instructions: "x",
          options: ["found"],
          state_contract: nil,
          version: 1
        })

      b =
        Canonical.question_hash(%{
          answer_type: Extraction,
          criteria: %{"type" => "string"},
          instructions: "x",
          options: ["found"],
          state_contract: nil,
          version: 1
        })

      refute a == b
    end

    test "to_question keeps caller-supplied criteria (declared data wins)" do
      assert {:ok, question} =
               Extraction.to_question("x", %{"doc" => "the declared schema"}, of: :date)

      assert question.criteria == %{"doc" => "the declared schema"}
    end

    test "output_schema: no confidence anywhere, status enum, narrowed source ids" do
      schema = Extraction.output_schema(of: :string, source_enum: ["a01", "a02"])

      assert schema["status"] == %{"enum" => ["found", "not_found", "ambiguous"]}

      assert schema["source_ids"] == %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => ["a01", "a02"]}
             }

      assert schema["value"] == %{"type" => "string"}
      refute Map.has_key?(schema, "confidence")
      refute Jason.encode!(schema) =~ "confidence"

      # The schema hash is the wire identity of the narrowed call: a
      # different packet mints a different wire_schema_hash.
      other = Extraction.output_schema(of: :string, source_enum: ["a01", "a03"])
      refute Canonical.digest(schema) == Canonical.digest(other)
    end

    test "value schema covers scalars, enums and composites" do
      assert Extraction.output_schema(of: :integer)["value"] == %{"type" => "integer"}
      assert Extraction.output_schema(of: :decimal)["value"]["pattern"] =~ "0-9"
      assert Extraction.output_schema(of: :boolean)["value"] == %{"type" => "boolean"}

      assert %{"enum" => ["low", "high"]} =
               Extraction.output_schema(of: :atom, constraints: [one_of: [:low, :high]])["value"]

      assert %{"type" => "object"} = Extraction.output_schema(of: :map)["value"]
    end
  end

  describe "the record wiring" do
    test "a judged extraction records kind, value and its cited atoms" do
      question = %{
        name: :deadline_extraction,
        version: 1,
        question_id: "judgment:v0:Probe#judgments/deadline_extraction",
        question_hash: "sha256:" <> String.duplicate("d", 64),
        question_version: 1,
        family: :contract_extraction,
        type: Extraction,
        constraints: [of: :string, source_enum: ["contract/§4"]],
        profile: :test_local,
        state_shape: nil,
        pii: :none,
        record: :must,
        pin: :required,
        instructions: "extract the deadline"
      }

      answer = %Extraction{
        status: :found,
        value: "2027-03-31",
        source_ids: ["contract/§4"]
      }

      ctx = %{judgments: %{observation_id: @obs}}
      timing = %{state: %{"text" => "x"}, latency_us: 5, mode: :live, key_inputs: %{}}

      inputs =
        AshJudgments.Ledger.Record.observation_inputs_for_test(question, answer, ctx, timing)

      assert inputs[:answer_kind] == :extraction
      assert inputs[:atom_ids] == ["contract/§4"]
      # A string extraction rides as-is; composites store as JSON text.
      assert inputs[:value] == "2027-03-31"
    end

    test "a composite extraction value stores as its JSON text" do
      question = %{
        name: :window_extraction,
        version: 1,
        question_id: "judgment:v0:Probe#judgments/window_extraction",
        question_hash: "sha256:" <> String.duplicate("d", 64),
        question_version: 1,
        family: :contract_extraction,
        type: Extraction,
        constraints: [of: :map],
        profile: :test_local,
        state_shape: nil,
        pii: :none,
        record: :must,
        pin: :required,
        instructions: "extract the window"
      }

      answer = %Extraction{status: :found, value: %{"from" => 1, "to" => 2}, source_ids: []}

      inputs =
        AshJudgments.Ledger.Record.observation_inputs_for_test(
          question,
          answer,
          %{judgments: %{}},
          %{state: %{}, latency_us: 5, mode: :live, key_inputs: %{}}
        )

      assert inputs[:value] == ~s({"from":1,"to":2})
    end
  end

  describe "the registry declaration contract" do
    test "an extraction question's options are the status enum" do
      body = """
      judgments do
        question :deadline do
          type AshJudgments.Evaluate.Extraction
          instructions "extract the deadline"
          version 1
          family :contract_extraction
          profile :test_local
          constraints(of: :string, source_enum: ["contract/§4"])
        end
      end
      """

      question = compiled_question(body)

      assert question.options == ["found", "not_found", "ambiguous"]
      assert question.type == Extraction
    end

    test "an extraction question without any source narrowing is refused" do
      warnings =
        assert_compile_error("""
        judgments do
          question :deadline do
            type AshJudgments.Evaluate.Extraction
            instructions "extract the deadline"
            version 1
            family :contract_extraction
            profile :test_local
            constraints(of: :string)
          end
        end
        """)

      assert warnings =~ "source_enum_from" or warnings =~ "source_enum"
    end

    test "explicit source ids outside the source attribute are refused" do
      warnings =
        assert_compile_error("""
        judgments do
          question :deadline do
            type AshJudgments.Evaluate.Extraction
            instructions "extract the deadline"
            version 1
            family :contract_extraction
            profile :test_local
            source_enum_from {AshJudgments.Test.Note, :body}
            constraints(of: :string, source_enum: ["not-in-the-attribute"])
          end
        end
        """)

      assert warnings =~ "are not in the source constraint"
    end
  end

  # The registry_test probe pattern: compile-only resources, no domain.
  defp compile_question(body, fixed_name \\ nil) do
    name =
      fixed_name ||
        Module.concat([AshJudgmentsExtractionTest, "Probe#{System.unique_integer([:positive])}"])

    source = """
    defmodule #{inspect(name)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshAi, AshJudgments.Registry]

      #{body}
    end
    """

    warnings =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:compiled, Code.compile_string(source, "ashjd_extraction_probe.ex")})
      end)

    case receive_compiled() do
      [{module, _beam} | _] when is_atom(module) ->
        {:ok, module |> AshJudgments.Registry.questions() |> List.first(), warnings}

      _other ->
        {:error, :no_module, warnings}
    end
  rescue
    error in [Spark.Error.DslError] -> {:error, :raised, Exception.message(error)}
  end

  defp receive_compiled do
    receive do
      {:compiled, results} -> results
    after
      1_000 -> :timeout
    end
  end

  defp compiled_question(body, fixed_name \\ nil) do
    case compile_question(body, fixed_name) do
      {:ok, question, _warnings} -> question
      {:error, kind, detail} -> flunk("probe did not compile (#{kind}):\n#{detail}")
    end
  end

  defp assert_compile_error(body, fixed_name \\ nil) do
    case compile_question(body, fixed_name) do
      {:ok, _question, warnings} ->
        assert warnings =~ "Spark.Error.DslError",
               "expected a verifier error, got none (warnings: #{inspect(warnings)})"

        warnings

      {:error, kind, detail} when kind in [:raised, :no_module] ->
        detail
    end
  end
end
