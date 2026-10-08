# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.EvidenceTest do
  @moduledoc """
  The evidence answer type (AST-97): the frozen §5.5 outcome vocabulary,
  the cast contract (reject, never repair), the cited-atom discipline
  (law 8), identity ([L]2: the outcome set IS the options enum), the
  narrowed wire schema — and one integration test per consumption site:
  the registry declaration (options + return constraints), the ledger
  record wiring (kind/atom_ids/value/distribution/confidence), the cache
  rebuild, the DMN bridge's band inputs, and the explore tier's outcome
  shape.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Cache
  alias AshJudgments.Evaluate.Evidence
  alias AshJudgments.Exploration
  alias AshJudgments.Registry.Canonical

  @outcome %{
    "choice" => "supports",
    "probabilities" => %{"supports" => 0.82, "contradicts" => 0.11, "insufficient" => 0.07},
    "confidence" => 0.9
  }

  ## The type's contract

  test "from_answer's map casts into the answer struct" do
    {:ok, map} = Evidence.from_answer(@outcome, %{})

    assert %Evidence{} = struct!(Evidence, map)
  end

  describe "round-trips (the frozen §5.5 vocabulary)" do
    test "the choice-shaped reply casts: disposition, distribution, confidence, ids" do
      assert {:ok,
              %{
                value: :supports,
                probabilities: %{
                  "supports" => 0.82,
                  "contradicts" => 0.11,
                  "insufficient" => 0.07
                },
                confidence: 0.9,
                source_ids: ["a01"]
              }} =
               Evidence.from_answer(
                 Map.put(@outcome, "source_ids", ["a01"]),
                 %{}
               )
    end

    test "source_ids default to the empty citation (the wire reply carries none)" do
      assert {:ok, %{source_ids: []}} = Evidence.from_answer(@outcome, %{})
    end

    test "the `evidence` key is the type's own alias for the choice shape" do
      assert {:ok, %{value: :contradicts}} =
               Evidence.from_answer(
                 %{"evidence" => "contradicts", "probabilities" => %{}, "confidence" => 0.4},
                 %{}
               )
    end

    test "not_applicable is in the frozen four" do
      assert {:ok, %{value: :not_applicable}} =
               Evidence.from_answer(
                 %{"choice" => "not_applicable", "probabilities" => %{}, "confidence" => 1.0},
                 %{}
               )
    end

    test "the distribution keeps STRING keys — the wire's shape, the record's shape" do
      {:ok, %{probabilities: probabilities}} = Evidence.from_answer(@outcome, %{})
      assert Enum.all?(Map.keys(probabilities), &is_binary/1)
    end

    test "constraints arrive as a keyword list from the action path and a map from direct calls" do
      enum = [source_enum: ["a01"]]

      assert {:ok, %{source_ids: ["a01"]}} =
               Evidence.from_answer(Map.put(@outcome, "source_ids", ["a01"]), enum)

      assert {:ok, %{source_ids: ["a01"]}} =
               Evidence.from_answer(Map.put(@outcome, "source_ids", ["a01"]), Map.new(enum))
    end
  end

  describe "constraint enforcement (reject, never repair)" do
    test "a disposition outside the frozen vocabulary is refused" do
      for outcome <- ["compliant", "admitted", "probably"] do
        assert {:error, error} =
                 Evidence.from_answer(
                   %{"choice" => outcome, "probabilities" => %{}, "confidence" => 0.5},
                   %{}
                 )

        assert error =~ "outside the vocabulary"
      end
    end

    test "wrong_scope is refused unless the question declares it" do
      assert {:error, error} =
               Evidence.from_answer(
                 %{"choice" => "wrong_scope", "probabilities" => %{}, "confidence" => 0.5},
                 %{}
               )

      assert error =~ "outside the vocabulary"

      assert {:ok, %{value: :wrong_scope}} =
               Evidence.from_answer(
                 %{"choice" => "wrong_scope", "probabilities" => %{}, "confidence" => 0.5},
                 %{wrong_scope: true}
               )
    end

    test "a probability key outside the vocabulary is refused — wrong_scope included" do
      assert {:error, error} =
               Evidence.from_answer(
                 %{@outcome | "probabilities" => %{"supports" => 0.9, "compliant" => 0.1}},
                 %{}
               )

      assert error =~ "probability key is outside the vocabulary"

      assert {:error, error} =
               Evidence.from_answer(
                 %{@outcome | "probabilities" => %{"supports" => 0.9, "wrong_scope" => 0.1}},
                 %{}
               )

      assert error =~ "wrong_scope"

      assert {:ok, _} =
               Evidence.from_answer(
                 %{@outcome | "probabilities" => %{"supports" => 0.9, "wrong_scope" => 0.1}},
                 %{wrong_scope: true}
               )
    end

    test "a probability outside 0..1 is refused" do
      assert {:error, error} =
               Evidence.from_answer(
                 %{@outcome | "probabilities" => %{"supports" => 1.5}},
                 %{}
               )

      assert error =~ "not a number in 0..1"
    end

    test "a confidence outside 0..1 is refused — reject, never clamp" do
      for confidence <- [1.5, -0.1, "high"] do
        assert {:error, error} =
                 Evidence.from_answer(
                   %{@outcome | "confidence" => confidence},
                   %{}
                 )

        assert error =~ "confidence is not a number in 0..1"
      end
    end

    test "a reply without the outcome key, or probabilities that are not a map, is refused" do
      assert {:error, _} = Evidence.from_answer(%{"probability" => 0.9}, %{})
      assert {:error, _} = Evidence.from_answer("supports", %{})
      assert {:error, error} = Evidence.from_answer(%{"choice" => "supports"}, %{})
      assert error =~ "probabilities"

      assert {:error, _} =
               Evidence.from_answer(
                 %{"choice" => :supports, "probabilities" => %{}, "confidence" => 0.5},
                 %{}
               )
    end
  end

  describe "source ids (the cited-atom discipline, law 8)" do
    test "ids outside the narrowed enum are refused" do
      assert {:error, error} =
               Evidence.from_answer(
                 Map.put(@outcome, "source_ids", ["a01", "fabricated"]),
                 %{source_enum: ["a01", "a02"]}
               )

      assert error =~ "outside the packet's enum"
      assert error =~ "fabricated"
    end

    test "ids inside the enum pass; no enum admits any string ids" do
      assert {:ok, %{source_ids: ["a01"]}} =
               Evidence.from_answer(
                 Map.put(@outcome, "source_ids", ["a01"]),
                 %{source_enum: ["a01", "a02"]}
               )

      assert {:ok, %{source_ids: ["anything"]}} =
               Evidence.from_answer(Map.put(@outcome, "source_ids", ["anything"]), %{})
    end

    test "non-string ids are refused even without a declared enum" do
      assert {:error, error} =
               Evidence.from_answer(Map.put(@outcome, "source_ids", [:a01]), %{})

      assert error =~ "atom ids"
    end
  end

  describe "identity ([L]2) and the wire schema" do
    test "to_question is a :choice over the frozen outcome set (ADR 0039)" do
      assert {:ok, question} = Evidence.to_question("does the evidence support it?", nil, %{})

      assert question.type == :choice

      assert question.criteria == %{
               "supports" => nil,
               "contradicts" => nil,
               "insufficient" => nil,
               "not_applicable" => nil
             }
    end

    test "to_question widens the outcome set when wrong_scope is declared" do
      assert {:ok, question} = Evidence.to_question("x", nil, %{wrong_scope: true})

      assert Enum.sort(Map.keys(question.criteria)) == [
               "contradicts",
               "insufficient",
               "not_applicable",
               "supports",
               "wrong_scope"
             ]
    end

    test "to_question keeps caller-supplied criteria (declared data wins, [L]2)" do
      criteria = %{"supports" => "the atoms entail the predicate"}

      assert {:ok, question} = Evidence.to_question("x", criteria, %{})
      assert question.criteria == criteria
    end

    test "the identity hash moves when the outcome set moves (wrong_scope widens the options)" do
      hash = fn constraints ->
        Canonical.question_hash(%{
          answer_type: Evidence,
          criteria: nil,
          instructions: "x",
          options: Enum.map(Evidence.dispositions(constraints), &Atom.to_string/1),
          state_contract: nil,
          version: 1
        })
      end

      refute hash.(%{}) == hash.(%{wrong_scope: true})
    end

    test "output_schema: the frozen enum on value AND probability keys, unit confidence" do
      schema = Evidence.output_schema(%{})

      assert schema["value"] == %{
               "type" => "string",
               "enum" => ["supports", "contradicts", "insufficient", "not_applicable"]
             }

      assert schema["probabilities"] == %{
               "type" => "object",
               "propertyNames" => %{
                 "enum" => ["supports", "contradicts", "insufficient", "not_applicable"]
               }
             }

      assert schema["confidence"] == %{"type" => "number", "minimum" => 0, "maximum" => 1}

      assert schema["source_ids"] == %{
               "type" => "array",
               "items" => %{"type" => "string", "enum" => []}
             }
    end

    test "output_schema widens with wrong_scope and narrows with the packet's enum" do
      schema = Evidence.output_schema(%{wrong_scope: true, source_enum: ["a01", "a02"]})

      assert schema["value"]["enum"] == [
               "supports",
               "contradicts",
               "insufficient",
               "not_applicable",
               "wrong_scope"
             ]

      assert schema["source_ids"]["items"]["enum"] == ["a01", "a02"]

      # The schema hash is the wire identity of the narrowed call: a
      # different packet mints a different wire_schema_hash.
      other = Evidence.output_schema(%{wrong_scope: true, source_enum: ["a01", "a03"]})

      refute Canonical.digest(schema) == Canonical.digest(other)
    end

    test "dispositions/0 is the frozen four, in §5.5 order" do
      assert Evidence.dispositions() == [:supports, :contradicts, :insufficient, :not_applicable]
    end
  end

  ## Integration: the registry declaration contract

  describe "the registry declaration contract" do
    test "an evidence question's options are the frozen outcome set" do
      body = """
      judgments do
        question :support do
          type AshJudgments.Evaluate.Evidence
          instructions "does the document support the control?"
          version 1
          family :evidence_probe
          profile :test_local
          constraints(source_enum: ["packet/a01"])
        end
      end
      """

      question = compiled_question(body)

      assert question.options == ["supports", "contradicts", "insufficient", "not_applicable"]
      assert question.type == Evidence
    end

    test "a declared wrong_scope widens the identity options" do
      body = """
      judgments do
        question :support do
          type AshJudgments.Evaluate.Evidence
          instructions "does the document support the control?"
          version 1
          family :evidence_probe
          profile :test_local
          constraints(wrong_scope: true)
        end
      end
      """

      question = compiled_question(body)

      assert question.options == [
               "supports",
               "contradicts",
               "insufficient",
               "not_applicable",
               "wrong_scope"
             ]
    end
  end

  ## Integration: the ledger record wiring

  describe "the record wiring" do
    test "a judged evidence records kind, the cited atoms, the collapsed value and the distribution" do
      question = %{
        name: :support_probe,
        version: 1,
        question_id: "judgment:v0:Probe#judgments/support_probe",
        question_hash: "sha256:" <> String.duplicate("e", 64),
        question_version: 1,
        family: :evidence_probe,
        type: Evidence,
        constraints: [],
        profile: :test_local,
        state_shape: nil,
        pii: :none,
        record: :must,
        pin: :required,
        instructions: "does the document support the control?"
      }

      answer = %Evidence{
        value: :supports,
        probabilities: %{"supports" => 0.82, "contradicts" => 0.11, "insufficient" => 0.07},
        confidence: 0.9,
        source_ids: ["packet/a01", "packet/a02"]
      }

      inputs =
        AshJudgments.Ledger.Record.observation_inputs_for_test(
          question,
          answer,
          %{judgments: %{}},
          %{state: %{"text" => "x"}, latency_us: 5, mode: :live, key_inputs: %{}}
        )

      assert inputs[:answer_kind] == :evidence
      # The cited atoms ARE the record's atoms (§5.5 lists source_ids for
      # evidence) — ids only, never quotations (law 8).
      assert inputs[:atom_ids] == ["packet/a01", "packet/a02"]
      assert inputs[:value] == "supports"

      assert inputs[:probabilities] == %{
               "supports" => "0.82",
               "contradicts" => "0.11",
               "insufficient" => "0.07"
             }

      assert Decimal.eq?(inputs[:confidence], "0.9")
    end

    test "a replayed/cache-hit evidence answer rebuilds from the recorded row" do
      record = %{
        value: "contradicts",
        probabilities: %{"contradicts" => "0.7", "insufficient" => "0.3"},
        confidence: Decimal.new("0.88"),
        atom_ids: ["packet/a01"]
      }

      question = %{type: Evidence, constraints: []}

      assert {:ok,
              %Evidence{
                value: :contradicts,
                probabilities: %{"contradicts" => 0.7, "insufficient" => 0.3},
                confidence: 0.88,
                source_ids: ["packet/a01"]
              }} = Cache.rebuild_answer(record, question)
    end
  end

  ## Integration: the DMN bridge's band inputs

  describe "the DMN bridge's band inputs" do
    @dmn_question %{name: :support_probe, type: Evidence, constraints: []}

    test "an evidence answer flattens to the p_<disposition> inputs + confidence" do
      inputs =
        Dmn.inputs(
          [
            %{
              question: @dmn_question,
              answer: %Evidence{
                value: :supports,
                probabilities: %{"supports" => 0.82, "insufficient" => 0.18},
                confidence: 0.9,
                source_ids: []
              },
              observation_id: "eeeeeeee-3333-4333-8333-333333333333"
            }
          ],
          family: "evidence_probe",
          risk_tier: "standard",
          jurisdiction: "ca"
        )

      assert inputs["support_probe__p_supports"] == "0.82"
      assert inputs["support_probe__p_contradicts"] == nil
      assert inputs["support_probe__p_insufficient"] == "0.18"
      assert inputs["support_probe__p_not_applicable"] == nil
      assert inputs["support_probe__confidence"] == "0.9"
      assert inputs["support_probe__present"] == "true"
      refute Map.has_key?(inputs, "support_probe__p_wrong_scope")
    end

    test "a wrong_scope answer carries p_wrong_scope where declared" do
      inputs =
        Dmn.inputs(
          [
            %{
              question: @dmn_question,
              answer: %Evidence{
                value: :wrong_scope,
                probabilities: %{"supports" => 0.0, "wrong_scope" => 1.0},
                confidence: 0.99,
                source_ids: []
              },
              observation_id: "eeeeeeee-3333-4333-8333-333333333333"
            }
          ],
          family: "evidence_probe",
          risk_tier: "standard",
          jurisdiction: "ca"
        )

      assert inputs["support_probe__p_wrong_scope"] == "1.0"
      assert inputs["support_probe__confidence"] == "0.99"
    end
  end

  ## Integration: the explore tier's outcome shape

  describe "the explore tier's outcome shape" do
    test "an exploratory evidence question derives its options from the frozen outcome set" do
      identity =
        Exploration.identity(%{
          type: Evidence,
          instructions: "does this note support an unsafe-transfer pattern?"
        })

      assert identity.options == ["supports", "contradicts", "insufficient", "not_applicable"]
      assert identity.answer_type == Evidence
      assert identity.version == 1

      widened =
        Exploration.identity(%{
          type: Evidence,
          instructions: "does this note support an unsafe-transfer pattern?",
          constraints: [wrong_scope: true]
        })

      assert widened.options == [
               "supports",
               "contradicts",
               "insufficient",
               "not_applicable",
               "wrong_scope"
             ]
    end
  end

  # The registry_test probe pattern: compile-only resources, no domain, no repo.
  defp compile_question(body) do
    name =
      Module.concat([AshJudgmentsEvidenceTest, "Probe#{System.unique_integer([:positive])}"])

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
        send(self(), {:compiled, Code.compile_string(source, "ashjd_evidence_probe.ex")})
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

  defp compiled_question(body) do
    case compile_question(body) do
      {:ok, question, _warnings} -> question
      {:error, kind, detail} -> flunk("probe did not compile (#{kind}):\n#{detail}")
    end
  end
end
