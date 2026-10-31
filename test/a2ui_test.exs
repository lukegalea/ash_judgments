# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.A2uiTest do
  @moduledoc """
  The judgment surfaces (AshJudgments.A2ui) bound to the test host's
  resources: each one builds an A2UI 1.0 surface, and the verdicts surface
  records a person's verdict through `AshJudgments.HumanVerdict.FromBanding`,
  as a click would, through `AshA2ui.ActionHandler`. S1-87: a row shows
  what is judged (subject, wording, the text opened as the actor, the
  lean), the answer is yes or no, and a verdict settles the duplicates
  `AwaitingVerdict` leaves out.
  """

  use ExUnit.Case, async: false

  @moduletag :db

  require Ash.Query

  alias AshJudgments.Calibration.ProposalDmn
  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Test.A2ui
  alias AshJudgments.Test.Banding
  alias AshJudgments.Test.HumanVerdict
  alias AshJudgments.Test.Judgment
  alias AshJudgments.Test.ReviewSource

  @person %{id: "person-1", email: "reviewer@example.test"}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_bandings test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, Judgment)
    Application.put_env(:ash_judgments, :review_source, ReviewSource)

    on_exit(fn ->
      for key <- [:region, :ledger, :review_source, :test_band_tables] do
        Application.delete_env(:ash_judgments, key)
      end
    end)

    :ok
  end

  describe "the surfaces" do
    test "each builds an A2UI 1.0 surface over the host's resource" do
      for ui <- [
            A2ui.VerdictsUI,
            A2ui.BandTablesUI,
            A2ui.CertificationsUI,
            A2ui.CalibrationUI,
            A2ui.FactsUI
          ] do
        messages = AshA2ui.Info.build_surface(ui)
        assert [_ | _] = messages, "#{inspect(ui)} built no messages"

        assert Enum.any?(messages, &Map.has_key?(&1, "createSurface")),
               "#{inspect(ui)} has no createSurface"
      end
    end

    test "the verdicts surface shows a row's subject, wording, text and lean to the actor" do
      put_table("1", %{"threshold" => "0.77"}, nil)

      judgment =
        judgment!(
          note_question(
            subject_id: "lib/app.ex#App.run/1",
            state_ciphertext: ReviewSource.seal("def run(x), do: x")
          )
        )

      review_banding!(judgment, p_true: "0.70")

      [%{"createSurface" => surface}] =
        AshA2ui.Info.build_surface(A2ui.VerdictsUI, actor: @person)

      rows = surface["dataModel"]["records"]
      assert [row] = rows
      assert row["question_text"] == "Does the note describe a follow-up commitment?"
      assert row["subject"] == "lib/app.ex#App.run/1"
      assert row["judged_excerpt"] == "def run(x), do: x"
      assert row["lean"] == "leans yes, 0.70; 0.77 admits without review"
    end

    test "the verdicts surface lists only review bandings that have no verdict" do
      waiting = review_banding!(judgment!())
      _admitted = banding!(judgment!(), band: :admit)
      verdicted = review_banding!(judgment!())
      assert {:ok, _} = record_verdict(verdicted, :yes)

      ids =
        Banding
        |> Ash.Query.for_read(:awaiting_verdict)
        |> Ash.read!()
        |> Enum.map(& &1.id)

      assert ids == [waiting.id]
    end

    test "the banding reads back its family, question and score for a reviewer" do
      banding = review_banding!(judgment!()) |> Ash.load!([:family, :question, :score])

      assert banding.family == "standards_commenting"
      assert banding.question == "comments_are_durable_facts_only"
      assert banding.score == "0.24"
    end
  end

  describe "what a row shows" do
    test "the subject and the question's declared wording" do
      judgment = judgment!(note_question(subject_id: "lib/app.ex#App.run/1"))
      banding = review_banding!(judgment) |> Ash.load!([:subject, :question_text])

      assert banding.subject == "lib/app.ex#App.run/1"
      assert banding.question_text == "Does the note describe a follow-up commitment?"
    end

    test "a reworded question shows no wording: the model was asked something else" do
      judgment =
        judgment!(note_question(question_hash: "sha256:" <> String.duplicate("f", 64)))

      assert %{question_text: nil} = review_banding!(judgment) |> Ash.load!(:question_text)

      # An id naming no module or question reads as none, and mints no atom.
      judgment = judgment!(question_id: "judgment:v0:No.Such.Module#judgments/no_such_q")
      assert %{question_text: nil} = review_banding!(judgment) |> Ash.load!(:question_text)
    end

    test "the lean in words, against the thresholds of the recorded table version" do
      put_table("1", %{"threshold" => "0.77"}, nil)
      banding = review_banding!(judgment!(), p_true: "0.7012") |> Ash.load!(:lean)
      assert banding.lean == "leans yes, 0.70; 0.77 admits without review"

      put_table("2", %{"threshold" => "0.77", "threshold_low" => "0.12"}, :admit_no)

      banding =
        review_banding!(judgment!(), p_true: "0.24", version: "2") |> Ash.load!(:lean)

      assert banding.lean ==
               "leans no, 0.24 for yes; 0.77 admits yes and 0.12 admits no without review"

      put_table("3", %{"threshold" => "0.77", "threshold_low" => "0.12"}, :omit)

      banding =
        review_banding!(judgment!(), p_true: "0.30", version: "3") |> Ash.load!(:lean)

      assert banding.lean ==
               "leans no, 0.30 for yes; 0.77 admits yes without review; 0.12 or below is dropped"
    end

    test "a score that rounds onto a threshold is shown as recorded" do
      put_table("1", %{"threshold" => "0.77"}, nil)
      banding = review_banding!(judgment!(), p_true: "0.7699") |> Ash.load!(:lean)
      assert banding.lean == "leans yes, 0.7699; 0.77 admits without review"
    end

    test "the lean says when the threshold cannot be read, rather than guess" do
      # No table registered for the banding's version.
      banding = review_banding!(judgment!(), p_true: "0.70") |> Ash.load!(:lean)
      assert banding.lean == "leans yes, 0.70; the threshold of its band table is not known here"

      # No review source at all.
      put_table("1", %{"threshold" => "0.77"}, nil)
      Application.delete_env(:ash_judgments, :review_source)
      banding = Ash.load!(banding, :lean, reuse_values?: false)
      assert banding.lean =~ "not known here"
    end

    test "the judged text, opened by the host's review source as the actor" do
      judgment = judgment!(state_ciphertext: ReviewSource.seal("  def run(x),\n do: x  "))
      banding = review_banding!(judgment)

      loaded = Ash.load!(banding, [:judged_text, :judged_excerpt], actor: @person)
      assert loaded.judged_text == "  def run(x),\n do: x  "
      assert loaded.judged_excerpt == "def run(x), do: x"
    end

    test "a long text is cut for the row at a word boundary, whole in the detail" do
      text = String.duplicate("word ", 100)
      banding = review_banding!(judgment!(state_ciphertext: ReviewSource.seal(text)))

      loaded = Ash.load!(banding, [:judged_text, :judged_excerpt], actor: @person)
      assert loaded.judged_text == text
      assert String.ends_with?(loaded.judged_excerpt, "word …")
      assert String.length(loaded.judged_excerpt) <= 282
    end

    test "the sealed text is not readable without an actor or without the host's source" do
      banding = review_banding!(judgment!(state_ciphertext: ReviewSource.seal("secret")))

      assert %{judged_text: nil, judged_excerpt: nil} =
               Ash.load!(banding, [:judged_text, :judged_excerpt])

      Application.delete_env(:ash_judgments, :review_source)

      assert %{judged_text: nil} = Ash.load!(banding, :judged_text, actor: @person)
    end
  end

  describe "one row per subject, question and unchanged text" do
    test "two bandings over the same unchanged text list once" do
      first = review_banding!(judgment!(subject_id: "doc#intro"))
      _second = review_banding!(judgment!(subject_id: "doc#intro"))
      other_text = review_banding!(judgment!(subject_id: "doc#intro", state: "changed"))
      other_subject = review_banding!(judgment!(subject_id: "doc#usage"))

      assert awaiting_ids() == Enum.sort([first.id, other_text.id, other_subject.id])
    end

    test "a banding of the same observation twice lists once" do
      judgment = judgment!()
      first = review_banding!(judgment)
      _again = review_banding!(judgment)

      assert awaiting_ids() == [first.id]
    end

    test "pagination counts the rows it lists" do
      for subject <- ["a", "b", "c"], _run <- 1..2 do
        review_banding!(judgment!(subject_id: subject))
      end

      page =
        Banding
        |> Ash.Query.for_read(:awaiting_verdict)
        |> Ash.Query.sort(banded_at: :asc)
        |> Ash.read!(page: [limit: 2, count: true])

      assert page.count == 3
      assert length(page.results) == 2
    end
  end

  describe "recording a verdict" do
    test "a click on Record verdict writes the person's verdict, snapshotting the model's answer" do
      judgment = judgment!()
      banding = review_banding!(judgment)

      assert {:ok, _messages} =
               AshA2ui.ActionHandler.handle(
                 A2ui.VerdictsUI,
                 %{
                   "name" => "invoke",
                   "context" => %{
                     "action" => "record_verdict",
                     "recordId" => banding.id,
                     "component" => "table",
                     "values" => %{"answer" => "no", "why" => "The comment narrates a change."}
                   }
                 },
                 actor: @person
               )

      assert [verdict] = Ash.read!(HumanVerdict)
      assert verdict.judgment_id == judgment.id
      assert verdict.human_value == "false"
      assert verdict.reason == "The comment narrates a change."
      assert verdict.reviewer == "reviewer@example.test"
      assert verdict.basis == :review_task
      assert verdict.question_hash == judgment.question_hash
      assert verdict.model_answer["kind"] == "noul"
      assert verdict.model_answer["probabilities"] == %{"true" => "0.24", "false" => "0.76"}
    end

    test "the prompt is a Yes/No picker labelled Answer, and the reason is Why" do
      view = AshA2ui.ResolvedView.resolve(A2ui.VerdictsUI)
      assert [answer, why] = view.prompts[:record_verdict]

      assert answer.label == "Answer"
      assert answer.choices == [{:yes, "Yes"}, {:no, "No"}]
      assert why.label == "Why"
    end

    test "yes/no atoms and strings are accepted" do
      for {action, answer, stored} <- [
            {:record_verdict, :yes, "true"},
            {:record_verdict, :no, "false"},
            {:record_verdict, "yes", "true"},
            {:record_text_verdict, "No", "false"},
            {:record_text_verdict, "true", "true"},
            {:record_text_verdict, :no, "false"}
          ] do
        judgment = judgment!()
        banding = review_banding!(judgment)

        assert {:ok, %{verdicts: 1}} = record_verdict(banding, answer, action: action)

        assert %{human_value: ^stored} =
                 HumanVerdict
                 |> Ash.Query.filter(judgment_id == ^judgment.id)
                 |> Ash.read_one!()
      end
    end

    test "a value outside the answer space is refused" do
      banding = review_banding!(judgment!())

      assert {:error, error} = record_verdict(banding, "maybe", action: :record_text_verdict)
      assert Exception.message(error) =~ "yes or no"

      assert {:error, _invalid} = record_verdict(banding, :maybe)
      assert {:error, _invalid} = record_verdict(banding, "maybe")
      assert [] = Ash.read!(HumanVerdict)
    end

    test "a verdict on one of two sibling bandings settles both, one verdict per observation" do
      first_judgment = judgment!(subject_id: "doc#intro")
      second_judgment = judgment!(subject_id: "doc#intro")
      changed = judgment!(subject_id: "doc#intro", state: "changed")

      first = review_banding!(first_judgment)
      second = review_banding!(second_judgment)
      unrelated = review_banding!(changed)

      assert awaiting_ids() == Enum.sort([first.id, unrelated.id])

      assert {:ok, %{verdicts: 2, bandings: 2}} = record_verdict(second, :no)

      verdicts = Ash.read!(HumanVerdict)

      assert Enum.sort(Enum.map(verdicts, & &1.judgment_id)) ==
               Enum.sort([first_judgment.id, second_judgment.id])

      assert Enum.all?(verdicts, &(&1.human_value == "false" and &1.basis == :review_task))

      # The changed text still waits for its own verdict.
      assert awaiting_ids() == [unrelated.id]
    end

    test "a sibling in another band, or with a verdict already, is not settled again" do
      admitted = banding!(judgment!(subject_id: "doc#intro"), band: :admit)
      verdicted = review_banding!(judgment!(subject_id: "doc#intro"))
      assert {:ok, %{verdicts: 1, bandings: 1}} = record_verdict(verdicted, :yes)

      # A later run over the same text: listed (its earlier siblings are
      # settled), and its verdict writes only its own.
      banding = review_banding!(judgment!(subject_id: "doc#intro"))
      assert awaiting_ids() == [banding.id]

      assert {:ok, %{verdicts: 1, bandings: 1}} = record_verdict(banding, :no)
      assert [_, _] = verdicts = Ash.read!(HumanVerdict)
      refute Enum.any?(verdicts, &(&1.judgment_id in admitted.observation_ids))
    end

    test "refuses a banding that is not in review" do
      banding = banding!(judgment!(), band: :admit)
      assert {:error, error} = record_verdict(banding, :yes)
      assert Exception.message(error) =~ "not in the review band"
      assert [] = Ash.read!(HumanVerdict)
    end

    test "refuses a second verdict" do
      banding = review_banding!(judgment!())
      assert {:ok, %{verdicts: 1}} = record_verdict(banding, :yes)
      assert {:error, error} = record_verdict(banding, :no)
      assert Exception.message(error) =~ "already has a verdict"
      assert [_one] = Ash.read!(HumanVerdict)
    end

    test "refuses with no actor: a verdict is a person's" do
      banding = review_banding!(judgment!())
      assert {:error, error} = record_verdict(banding, :yes, actor: nil)
      assert Exception.message(error) =~ "person"
    end
  end

  defp record_verdict(banding, answer, opts \\ []) do
    Banding
    |> Ash.ActionInput.for_action(
      Keyword.get(opts, :action, :record_verdict),
      %{record_id: banding.id, answer: answer},
      actor: Keyword.get(opts, :actor, @person)
    )
    |> Ash.run_action()
  end

  defp awaiting_ids do
    Banding
    |> Ash.Query.for_read(:awaiting_verdict)
    |> Ash.read!()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  # A band table version the review source can read back, rendered by
  # ProposalDmn as a certified table would be.
  defp put_table(version, thresholds, low_band) do
    {:ok, xml} =
      ProposalDmn.render(
        %{
          "definition_key" => "judgments_band_standards_commenting",
          "family_tag" => "judgments:family:standards_commenting",
          "thresholds" => thresholds
        },
        low_band: low_band,
        score_input: "comments_are_durable_facts_only__p_true"
      )

    tables = Application.get_env(:ash_judgments, :test_band_tables, %{})
    Application.put_env(:ash_judgments, :test_band_tables, Map.put(tables, version, xml))
  end

  defp note_question(overrides) do
    Keyword.merge(
      [
        question_id: Canonical.question_id(AshJudgments.Test.Note, :notes_follow_up),
        question_hash: AshJudgments.Registry.hash(AshJudgments.Test.Note, :notes_follow_up),
        family: "clinic_notes"
      ],
      overrides
    )
  end

  defp judgment!(overrides \\ []) do
    {state, overrides} = Keyword.pop(overrides, :state, "synthetic")

    Judgment
    |> Ash.Changeset.for_create(
      :record,
      Keyword.merge(
        [
          question_id:
            "judgment:v0:AshJudgments.Test.Note#judgments/comments_are_durable_facts_only",
          question_hash: "sha256:" <> String.duplicate("a", 64),
          question_version: 1,
          family: "standards_commenting",
          subject_type: "AshJudgments.Test.Note",
          subject_id: "note-#{System.unique_integer([:positive])}",
          state_digest: Canonical.digest(Canonical.encode(%{"text" => state})),
          answer_kind: :noul,
          value: nil,
          probabilities: %{"true" => "0.24", "false" => "0.76"},
          model_spec_requested: "typesafe:test-model",
          model_version: "test-model-1.0.0",
          model_digest: "sha256:" <> String.duplicate("b", 64),
          runtime_version: "0.9.0",
          profile: "test_local"
        ],
        overrides
      )
    )
    |> Ash.create!()
  end

  defp review_banding!(judgment, opts \\ []),
    do: banding!(judgment, Keyword.put(opts, :band, :review))

  defp banding!(judgment, opts) do
    p_true = Keyword.get(opts, :p_true, "0.24")

    Banding
    |> Ash.Changeset.for_create(:record, %{
      observation_ids: [judgment.id],
      band: Keyword.fetch!(opts, :band),
      reason_code: "below_conformal_threshold",
      matched_rule_ids: ["rule_review"],
      band_table: %{
        "definition_key" => "judgments_band_standards_commenting",
        "definition_version" => Keyword.get(opts, :version, "1")
      },
      decision_evaluation_id: Ash.UUID.generate(),
      inputs: %{
        "family" => "standards_commenting",
        "comments_are_durable_facts_only__present" => "true",
        "comments_are_durable_facts_only__observation_id" => judgment.id,
        "comments_are_durable_facts_only__p_true" => p_true,
        "comments_are_durable_facts_only__p_false" => "0.76"
      },
      mode: :live
    })
    |> Ash.create!()
  end
end
