# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.RegistryTest do
  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  alias AshJudgments.Registry
  alias AshJudgments.Registry.Canonical

  describe "the compiled declaration (AC-1)" do
    test "options_from derives the Choice options from the attribute's enum, abstain appended" do
      question = Registry.question(AshJudgments.Test.Appointment, :triage_urgency)

      assert %Registry.Question{} = question
      assert question.options == [:emergency, :urgent, :soon, :routine, :insufficient]
    end

    test "renaming an enum value changes question_hash — the options are in the hashed object" do
      question = Registry.question(AshJudgments.Test.Appointment, :triage_urgency)

      renamed = hash_with(options: [:emergency, :urgent, :soon, :someday, :insufficient])

      assert renamed != question.question_hash
    end

    test "Noul's options are [true, false]; Score's are the ordered levels" do
      assert %{options: [true, false]} =
               Registry.question(AshJudgments.Test.Note, :notes_follow_up)

      scored =
        compiled_question("""
          judgments do
            question :scored do
              type AshAi.Evaluate.Score
              constraints levels: ["Routine", "Time-sensitive", "Urgent"]
              instructions "How urgent?"
              version 1
              family :test
              profile :test_local
            end
          end
        """)

      assert scored.options == ["Routine", "Time-sensitive", "Urgent"]
    end

    test "the question id uses the RFC grammar (§3.1)" do
      question = Registry.question(AshJudgments.Test.Appointment, :triage_urgency)

      assert question.question_id ==
               "judgment:v0:AshJudgments.Test.Appointment#judgments/triage_urgency"
    end

    test "state_contract is the digest of the projection's declared shape" do
      question = Registry.question(AshJudgments.Test.Note, :notes_follow_up)

      assert question.state_contract ==
               "sha256:" <>
                 (:crypto.hash(
                    :sha256,
                    Canonical.encode(%{"text" => "string"})
                  )
                  |> Base.encode16(case: :lower))
    end
  end

  describe "question_hash (AC-2)" do
    test "is a full sha256 digest, deterministic for the same declaration" do
      question = Registry.question(AshJudgments.Test.Appointment, :triage_urgency)

      assert String.starts_with?(question.question_hash, "sha256:")
      assert byte_size(question.question_hash) == byte_size("sha256:") + 64

      assert question.question_hash ==
               Registry.hash(AshJudgments.Test.Appointment, :triage_urgency)
    end

    test "the canonical JSON sorts keys — key order in structured instructions cannot matter" do
      assert Canonical.encode(%{"b" => 1, "a" => %{"y" => 2, "x" => 3}}) ==
               ~s({"a":{"x":3,"y":2},"b":1})

      h1 = hash_with(instructions: %{"text" => "t", "meta" => %{"b" => 1, "a" => 2}})
      h2 = hash_with(instructions: %{"meta" => %{"a" => 2, "b" => 1}, "text" => "t"})
      assert h1 == h2
    end

    test "whitespace inside instructions is NOT normalised — a wording change is a new question" do
      # The RFC's canonical rules (§4.3, via semantic-manifest §7.2)
      # normalise JSON structure but never string values. That is the
      # decision behind AC-2's "only if whitespace is normalised by the
      # canonical rule": it is not, so even whitespace-only rewording mints
      # a new hash, and the lock check (AC-3) demands the version bump.
      refute hash_with(instructions: "Does the note describe a follow-up?") ==
               hash_with(instructions: "Does the note describe a  follow-up?")
    end

    test "changes whenever any identity field changes; never when family changes (Q3)" do
      base = hash_with([])

      refute base == hash_with(instructions: "Different wording")
      refute base == hash_with(criteria: %{emergency: "different"})
      refute base == hash_with(version: 2)
      refute base == hash_with(answer_type: AshAi.Evaluate.Noul)
      refute base == hash_with(state_contract: "sha256:" <> String.duplicate("0", 64))

      # Option ORDER is part of identity (arrays keep declaration order)...
      refute hash_with(options: [:a, :b, :insufficient]) ==
               hash_with(options: [:b, :a, :insufficient])

      # ...but the family is outside the hash (RFC §3.2, Q3): moving a
      # question between families is governance, not a new question.
      assert base == hash_with(family: :some_other_family)
    end

    test "an undeclared state contract hashes as null, never as the digest of empty (§4.2)" do
      assert Canonical.state_contract(nil) == nil

      # The digest of nothing is nil — never the digest of "%{}"...
      refute Canonical.state_contract(%{}) == nil
      assert Canonical.state_contract(%{}) != Canonical.state_contract(nil)

      # ...and the contract is part of identity: declaring one changes the
      # question.
      refute hash_with(state_contract: nil) == hash_with([])
    end

    test "real numbers canonicalise as shortest round-trip decimal strings (§4.3)" do
      assert Canonical.encode(%{"p" => 0.9412}) == ~s({"p":"0.9412"})
      assert Canonical.encode(%{"p" => 1.0}) == ~s({"p":"1.0"})
    end
  end

  describe "the verifiers (AC-4)" do
    test "pii :minimised without a state_projection fails at compile time" do
      warnings =
        assert_compile_error("""
          judgments do
            question :private_note do
              type AshAi.Evaluate.Noul
              instructions "Does the note mention a fall?"
              version 1
              family :clinic_notes
              profile :test_local
              pii :minimised
            end
          end
        """)

      assert warnings =~ "pii: :minimised requires a state_projection"
    end

    test "record :must with pin :optional is refused" do
      warnings =
        assert_compile_error("""
          judgments do
            question :unpinned do
              type AshAi.Evaluate.Noul
              instructions "Does the note mention a fall?"
              version 1
              family :clinic_notes
              profile :test_local
              record :must
              pin :optional
            end
          end
        """)

      assert warnings =~ "record: :must implies pin: :required"
    end

    test "explicit options outside the source constraint are refused" do
      warnings =
        assert_compile_error("""
          judgments do
            question :overflowing do
              type AshAi.Evaluate.Choice
              options_from {AshJudgments.Test.Appointment, :triage_urgency}
              constraints of: [:emergency, :telepathy]
              instructions "Which triage band?"
              version 1
              family :clinic_triage
              profile :test_local
            end
          end
        """)

      assert warnings =~ "not in the source constraint"
      assert warnings =~ ":telepathy"
    end

    test "a Choice with neither options_from nor of is refused" do
      warnings =
        assert_compile_error("""
          judgments do
            question :optionless do
              type AshAi.Evaluate.Choice
              instructions "Which triage band?"
              version 1
              family :clinic_triage
              profile :test_local
            end
          end
        """)

      assert warnings =~ "needs `options_from"
    end

    test "a Score without levels is refused" do
      warnings =
        assert_compile_error("""
          judgments do
            question :levelless do
              type AshAi.Evaluate.Score
              instructions "How urgent?"
              version 1
              family :clinic_triage
              profile :test_local
            end
          end
        """)

      assert warnings =~ "needs `constraints levels:`"
    end
  end

  describe "the lock check (AC-3)" do
    @declaration """
      judgments do
        question :watched do
          type AshAi.Evaluate.Noul
          instructions "Does the note mention a fall?"
          version VERSION
          family :clinic_notes
          profile :test_local
          state_projection AshJudgments.Test.Projections.NoteText
        end
      end
    """

    setup do
      path = Path.join(System.tmp_dir!(), "ashjd_lock_#{System.unique_integer([:positive])}.json")
      Application.put_env(:ash_judgments, :lock_path, path)
      on_exit(fn -> Application.delete_env(:ash_judgments, :lock_path) end)
      %{path: path}
    end

    test "a changed instruction without a version bump fails compilation, naming both hashes", %{
      path: path
    } do
      question =
        compiled_question(
          @declaration |> String.replace("VERSION", "1"),
          Module.concat([AshJudgmentsRegistryTest, "LockProbe"])
        )

      File.write!(
        path,
        Jason.encode!(%{
          question.question_id => %{"hash" => question.question_hash, "version" => 1}
        })
      )

      reworded =
        @declaration
        |> String.replace("VERSION", "1")
        |> String.replace("mention a fall", "mention a slip")

      message =
        assert_compile_error(reworded, Module.concat([AshJudgmentsRegistryTest, "LockProbe"]))

      assert message =~ "changed without a version bump"
      assert message =~ question.question_id

      # Both hashes, named: the declared one and the locked one, and they
      # must differ (the whole point).
      assert [declared, locked] =
               Regex.run(
                 ~r/declared (sha256:[0-9a-f]{64}), locked (sha256:[0-9a-f]{64})/,
                 message
               )
               |> tl()

      assert locked == question.question_hash
      refute declared == locked
    end

    test "a changed instruction WITH a version bump compiles", %{path: path} do
      question =
        compiled_question(
          @declaration |> String.replace("VERSION", "1"),
          Module.concat([AshJudgmentsRegistryTest, "LockProbe"])
        )

      File.write!(
        path,
        Jason.encode!(%{
          question.question_id => %{"hash" => question.question_hash, "version" => 1}
        })
      )

      reworded =
        @declaration
        |> String.replace("VERSION", "2")
        |> String.replace("mention a fall", "mention a slip")

      assert %Registry.Question{version: 2} =
               compiled_question(reworded, Module.concat([AshJudgmentsRegistryTest, "LockProbe"]))
    end

    test "an empty lock opts the host in without constraining anything", %{path: path} do
      File.write!(path, "[]")

      assert %Registry.Question{} =
               compiled_question(@declaration |> String.replace("VERSION", "1"))
    end

    test "an unreadable lock is never silently skipped", %{path: path} do
      File.write!(path, "{not json")

      message =
        assert_compile_error(@declaration |> String.replace("VERSION", "1"))

      assert message =~ "could not be read"
    end
  end

  describe "the generated judge action (AC-5)" do
    setup :configure_stack

    test "the state on the wire is the projection's output, never the full input" do
      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

      answer =
        AshJudgments.Test.Note
        |> Ash.ActionInput.for_action(:judge_notes_follow_up, %{
          "input" => %{
            "text" => "The resident will need a follow-up appointment next week.",
            "patient_id" => "P-should-never-leave"
          }
        })
        |> Ash.run_action!(context: %{judgments: %{req_llm: AshJudgments.Test.FakeReqLLM}})

      # The answer came from upstream's casting of the canned reply.
      assert %AshAi.Evaluate.Noul{probability: 0.9} = answer

      assert_receive {:judge_call, spec, state, questions}
      # The spec is the profile's resolved model; the state is the
      # projection's output — the note text, and never `patient_id`.
      assert %{id: "test-model"} = spec
      assert state == %{"text" => "The resident will need a follow-up appointment next week."}
      assert map_size(questions) == 1
      assert [{_key, question}] = Enum.to_list(questions)
      assert question.instructions =~ "follow-up commitment"
    end

    test "the matrix action asks runtime questions and returns one answer per element" do
      put_test_env(%{"JUDGE_BASE_URL" => "http://127.0.0.1:11435", "JUDGE_API_KEY" => "local"})

      answers =
        AshJudgments.Test.Note
        |> Ash.ActionInput.for_action(:judge_notes_follow_up_matrix, %{
          "input" => %{"text" => "synthetic note"},
          "questions" => [
            %{"instructions" => "Is a follow-up mentioned?"},
            %{"instructions" => "Is a medication change mentioned?"}
          ]
        })
        |> Ash.run_action!(context: %{judgments: %{req_llm: AshJudgments.Test.FakeReqLLM}})

      assert [%AshAi.Evaluate.Noul{probability: 0.9}, %AshAi.Evaluate.Noul{probability: 0.9}] =
               answers

      assert_receive {:judge_call, _spec, _state, questions}
      assert map_size(questions) == 2

      # The runtime questions went over the wire as asked — with the
      # caller's wording, not the declaration's.
      sent_instructions =
        questions |> Map.values() |> Enum.map(& &1.instructions) |> Enum.sort()

      assert sent_instructions == [
               "Is a follow-up mentioned?",
               "Is a medication change mentioned?"
             ]
    end
  end

  describe "expose_as_tool? (AC-7)" do
    test "the generated tool exists and wraps only the read-only judge action" do
      tool =
        Enum.find(
          AshAi.Info.tools(AshJudgments.Test.Appointment),
          &(&1.name == :judge_triage_urgency)
        )

      assert %AshAi.Tool{} = tool
      assert tool.action == :judge_triage_urgency
      assert tool.resource == AshJudgments.Test.Appointment

      # The wrapped action is the generated generic judge — read-only by
      # construction; no tool exists for a question without expose_as_tool?.
      assert %{type: :action} =
               Ash.Resource.Info.action(AshJudgments.Test.Appointment, :judge_triage_urgency)

      refute Enum.any?(
               AshAi.Info.tools(AshJudgments.Test.Note),
               &(&1.name == :judge_notes_follow_up)
             )
    end

    test "the generated actions exist on the resource" do
      actions = Ash.Resource.Info.actions(AshJudgments.Test.Appointment)
      assert Enum.any?(actions, &(&1.name == :judge_triage_urgency))
      assert Enum.any?(actions, &(&1.name == :judge_triage_urgency_matrix))
    end
  end

  ## Helpers

  defp hash_with(overrides) do
    question = Registry.question(AshJudgments.Test.Appointment, :triage_urgency)

    declaration =
      %{
        answer_type: question.type,
        criteria: question.criteria,
        instructions: question.instructions,
        options: question.options,
        state_contract: question.state_contract,
        version: question.version
      }
      |> Map.merge(Map.new(overrides))

    Canonical.question_hash(declaration)
  end

  # Compiles a throwaway resource carrying one `judgments` block, in a
  # uniquely-named module. Returns {:ok, question, warnings}.
  #
  # No `domain:`: the probes are compile-only (declaration + verifiers); a
  # domain that does not accept them would raise in Ash's own verifier and
  # abort the phase before this package's verifiers run.
  #
  # Spark reports verifier DslErrors as compile warnings when a module is
  # compiled via Code.compile_string (outside Mix's compile); under a real
  # `mix compile` the same errors fail the build. The severity is
  # compile-context — the ERROR is the verifier's, and the negative tests
  # assert on its text.
  defp compile_question(body, fixed_name \\ nil) do
    name =
      fixed_name ||
        Module.concat([AshJudgmentsRegistryTest, "Probe#{System.unique_integer([:positive])}"])

    source = """
    defmodule #{inspect(name)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshAi, AshJudgments.Registry]

      #{body}
    end
    """

    # capture_io/2 returns just the captured output; the compile result
    # comes back through the mailbox.
    warnings =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:compiled, Code.compile_string(source, "ashjd_registry_probe.ex")})
      end)

    case receive_compiled() do
      [{module, _beam} | _] when is_atom(module) ->
        {:ok, module |> Registry.questions() |> List.first(), warnings}

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

  # The negative form: the declaration is rejected. Under Code.compile_string
  # Spark reports verifier DslErrors as compile warnings (under a real
  # `mix compile` the same errors fail the build — severity is
  # compile-context; the ERROR is the verifier's). Returns the error text.
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
