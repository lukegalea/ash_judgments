# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.A2uiTest do
  @moduledoc """
  The judgment surfaces (AshJudgments.A2ui) bound to the test host's
  resources: each one builds an A2UI 1.0 surface, and the verdicts surface
  records a person's verdict through `AshJudgments.HumanVerdict.FromBanding`,
  as a click would, through `AshA2ui.ActionHandler`.
  """

  use ExUnit.Case, async: false

  @moduletag :db

  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Test.A2ui
  alias AshJudgments.Test.Banding
  alias AshJudgments.Test.HumanVerdict
  alias AshJudgments.Test.Judgment

  @person %{id: "person-1", email: "reviewer@example.test"}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <- ~w(test_judgments test_human_verdicts test_bandings test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo)
    Application.put_env(:ash_judgments, :region, :ca)
    on_exit(fn -> Application.delete_env(:ash_judgments, :region) end)
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

    test "the verdicts surface lists only review bandings that have no verdict" do
      waiting = review_banding!(judgment!())
      _admitted = banding!(judgment!(), band: :admit)
      verdicted = review_banding!(judgment!())
      assert {:ok, _} = record_verdict(verdicted, "yes")

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
                     "values" => %{"value" => "No", "reason" => "The comment narrates a change."}
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

    test "refuses a banding that is not in review" do
      banding = banding!(judgment!(), band: :admit)
      assert {:error, error} = record_verdict(banding, "yes")
      assert Exception.message(error) =~ "not in the review band"
      assert [] = Ash.read!(HumanVerdict)
    end

    test "refuses a second verdict" do
      banding = review_banding!(judgment!())
      assert {:ok, %{verdicts: 1}} = record_verdict(banding, "yes")
      assert {:error, error} = record_verdict(banding, "no")
      assert Exception.message(error) =~ "already has a verdict"
      assert [_one] = Ash.read!(HumanVerdict)
    end

    test "refuses a value outside a yes/no question's answers" do
      banding = review_banding!(judgment!())
      assert {:error, error} = record_verdict(banding, "maybe")
      assert Exception.message(error) =~ "yes or no"
    end

    test "refuses with no actor: a verdict is a person's" do
      banding = review_banding!(judgment!())
      assert {:error, error} = record_verdict(banding, "yes", actor: nil)
      assert Exception.message(error) =~ "person"
    end
  end

  defp record_verdict(banding, value, opts \\ []) do
    Banding
    |> Ash.ActionInput.for_action(:record_verdict, %{record_id: banding.id, value: value},
      actor: Keyword.get(opts, :actor, @person)
    )
    |> Ash.run_action()
  end

  defp judgment!(overrides \\ []) do
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
          state_digest: Canonical.digest(Canonical.encode(%{"text" => "synthetic"})),
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

  defp review_banding!(judgment), do: banding!(judgment, band: :review)

  defp banding!(judgment, band: band) do
    Banding
    |> Ash.Changeset.for_create(:record, %{
      observation_ids: [judgment.id],
      band: band,
      reason_code: "below_conformal_threshold",
      matched_rule_ids: ["rule_review"],
      band_table: %{
        "definition_key" => "judgments_band_standards_commenting",
        "definition_version" => "1"
      },
      decision_evaluation_id: Ash.UUID.generate(),
      inputs: %{
        "family" => "standards_commenting",
        "comments_are_durable_facts_only__present" => "true",
        "comments_are_durable_facts_only__observation_id" => judgment.id,
        "comments_are_durable_facts_only__p_true" => "0.24",
        "comments_are_durable_facts_only__p_false" => "0.76"
      },
      mode: :live
    })
    |> Ash.create!()
  end
end
