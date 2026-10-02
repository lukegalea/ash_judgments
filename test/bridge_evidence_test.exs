# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.BridgeEvidenceTest do
  @moduledoc """
  The evidence bridge (AST-95): the observation → EvidenceArtifact
  convention, per answer kind, banded and un-banded, with the no-text
  invariant asserted across all of it, the collector format, extraction
  source ids, and the missing-dependency degradation.
  """

  use ExUnit.Case, async: false

  alias AshJudgments.Bridge.Evidence
  alias AshJudgments.Registry.Canonical

  @org "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @control "SI-6"

  # A marker that must NEVER appear in any artifact attribute (§9 rule 1):
  # the observations below carry it as document text / state body.
  @doc_text "TOMATO_REVIEW_THE_CONTRACT_TOMATO"

  @digest "sha256:" <> String.duplicate("b", 64)
  @question_hash "sha256:" <> String.duplicate("a", 64)
  @doc_hash "sha256:" <> String.duplicate("c", 64)

  setup do
    # The house DB pattern (ledger_test et al): manual ownership outside
    # the sandbox, tables cleared per test.
    Ecto.Adapters.SQL.Sandbox.checkout(AshJudgments.TestRepo, sandbox: false)

    for table <-
          ~w(test_judgments test_human_verdicts test_facts test_bandings test_band_table_certifications test_event_log) do
      AshJudgments.TestRepo.query!("DELETE FROM " <> table)
    end

    # Every ledger row carries its region (law 10) — the stack config may
    # have been cycled by another test's on_exit.
    Application.put_env(:ash_judgments, :region, :ca)
    Application.put_env(:ash_judgments, :ledger, AshJudgments.Test.Judgment)
    Application.put_env(:ash_judgments, :banding, AshJudgments.Test.Banding)
    Application.put_env(:ash_judgments, :facts, AshJudgments.Test.Fact)

    on_exit(fn ->
      Application.delete_env(:ash_judgments, :ledger)
      Application.delete_env(:ash_judgments, :banding)
      Application.delete_env(:ash_judgments, :facts)
    end)

    :ok
  end

  defp record_observation(kind_overrides) do
    base = [
      id: Ash.UUID.generate(),
      question_id: "judgment:v0:AshJudgments.Test.Note#judgments/notes_follow_up",
      question_hash: @question_hash,
      question_version: 1,
      family: "note_review",
      subject_type: "AshJudgments.Test.Note",
      subject_id: "note-1",
      document_hash: @doc_hash,
      state_digest: Canonical.digest(Canonical.encode(%{"text" => @doc_text})),
      answer_kind: :noul,
      value: nil,
      probabilities: %{"p" => "0.94"},
      confidence: Decimal.new("0.94"),
      model_spec_requested: "typesafe:test-model",
      model_version: "test-model-1.0.0",
      model_digest: @digest,
      runtime_version: "0.7.5",
      profile: "test_local",
      latency_us: 1_234,
      mode: :live
    ]

    AshJudgments.Test.Judgment
    |> Ash.Changeset.for_create(:record, Keyword.merge(base, kind_overrides))
    |> Ash.create!()
  end

  defp record_banding(observation_id, band \\ :admit) do
    # fact_value is admit-only (§7.1): a review or omit banding proposes
    # no fact value.
    fact_value = if band == :admit, do: %{"p" => "0.94"}

    AshJudgments.Test.Banding
    |> Ash.Changeset.for_create(:record, %{
      observation_ids: [observation_id],
      band: band,
      fact_value: fact_value,
      matched_rule_ids: ["decision-table-row-3"],
      band_table: %{
        "definition_key" => "note_bands",
        "definition_version" => "3",
        "content_hash" => "sha256:" <> String.duplicate("7", 64),
        "definition_id" => "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        "tenant_fork" => nil
      },
      decision_evaluation_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      inputs: %{"notes_follow_up__p" => "0.94", "family" => "note_review"},
      mode: :live,
      correlation_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    })
    |> Ash.create!()
  end

  defp attrs_for(observation, banding \\ nil, extra_opts \\ []) do
    Evidence.artifact_attrs(
      observation,
      banding,
      Keyword.merge([organization_id: @org, control_id: @control], extra_opts)
    )
  end

  describe "the convention, per answer kind" do
    test "a noul observation maps onto :examine with the digest-forward collector" do
      observation = record_observation([])
      attrs = attrs_for(observation)

      assert attrs.method == :examine
      assert attrs.hash == @doc_hash
      assert attrs.subject_type == "AshJudgments.Test.Note"
      assert attrs.subject_id == "note-1"
      assert attrs.organization_id == @org
      assert attrs.control_id == @control
      assert %DateTime{} = attrs.collected_at

      # The collector names the model digest and is version-qualified ([L]3).
      assert attrs.collector == "systemone:#{@digest}@0.7.5"
      assert attrs.collector =~ ~r/^systemone:sha256:[0-9a-f]{64}@.+$/

      # Entry 1: judged, at the observation's timestamp, in the zone.
      [entry] = attrs.chain_of_custody
      assert entry.action == "judged"
      assert entry.actor == attrs.collector
      assert entry.at == observation.recorded_at
      assert entry.location == "ca"
      assert entry.judgment_id == observation.id
      assert entry.banding_id == nil
      assert entry.question_hash == @question_hash
      assert entry.band_table == nil
      assert entry.admission_id == nil
    end

    test "a choice observation maps with its value answer untouched" do
      observation =
        record_observation(
          answer_kind: :choice,
          value: "follow_up",
          confidence: Decimal.new("0.8")
        )

      attrs = attrs_for(observation)
      [entry] = attrs.chain_of_custody
      assert entry.action == "judged"
      assert attrs.hash == @doc_hash
    end

    test "a score observation maps the same way" do
      observation =
        record_observation(answer_kind: :score, value: "4", probabilities: nil, confidence: nil)

      attrs = attrs_for(observation)
      [entry] = attrs.chain_of_custody
      assert entry.action == "judged"
    end

    # The extraction kind is spelled :evidence in the frozen v0 schema
    # (`:extraction` is the extraction-type ticket's name for it).
    test "an extraction observation carries its source atom ids only, never quotations" do
      observation =
        record_observation(
          answer_kind: :evidence,
          value: "found",
          atom_ids: ["contract/§4/deadline", "contract/§7/penalty"]
        )

      attrs = attrs_for(observation)
      [entry] = attrs.chain_of_custody

      assert entry.atom_ids == ["contract/§4/deadline", "contract/§7/penalty"]

      # Ids, never quotations: the atom ids are the only content-shaped
      # keys, and none of them is the document text.
      refute @doc_text =~ "§4/deadline"
      assert Map.has_key?(entry, :atom_ids)
    end
  end

  describe "banded vs un-banded" do
    test "a nil banding yields exactly one custody entry" do
      observation = record_observation([])
      attrs = attrs_for(observation)

      assert length(attrs.chain_of_custody) == 1
    end

    test "a banding appends the admission entry, per band, in the past tense" do
      for {band, action} <- [{:admit, "admitted"}, {:review, "reviewed"}, {:omit, "omitted"}] do
        observation = record_observation([])
        banding = record_banding(observation.id, band)

        attrs =
          attrs_for(observation, banding, admission_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")

        [judged, banded] = attrs.chain_of_custody

        assert judged.action == "judged"
        assert banded.action == action
        assert banded.at == banding.banded_at
        assert banded.location == "ca"
        assert banded.judgment_id == observation.id
        assert banded.banding_id == banding.id
        assert banded.question_hash == @question_hash

        # The band-table content hash as RECORDED — the bridge re-evaluates
        # nothing (bridges decide nothing).
        assert banded.band_table == "sha256:" <> String.duplicate("7", 64)
        assert banded.admission_id == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

        # Entry 1 stays untouched by the banding.
        assert judged.banding_id == nil
        assert judged.admission_id == nil
      end
    end

    test "the admission actor is the opts override, defaulting to the collector" do
      observation = record_observation([])
      banding = record_banding(observation.id)

      default = attrs_for(observation, banding)
      assert hd(tl(default.chain_of_custody)).actor == default.collector

      overridden =
        attrs_for(observation, banding, admission_actor: "systemone:band-table-automation")

      assert hd(tl(overridden.chain_of_custody)).actor == "systemone:band-table-automation"
    end
  end

  describe "the no-text invariant (§9 rule 1, law 8)" do
    test "no attribute carries document text — any kind, banded or not" do
      kinds = [
        [],
        [answer_kind: :choice, value: "follow_up"],
        [answer_kind: :score, value: "4"],
        [answer_kind: :evidence, value: "found", atom_ids: ["contract/§4"]],
        [answer_kind: :evidence, value: "ambiguous", atom_ids: []]
      ]

      for overrides <- kinds, banding? <- [false, true] do
        observation = record_observation(overrides)

        banding =
          if banding? do
            record_banding(observation.id, :review)
          else
            nil
          end

        attrs = attrs_for(observation, banding)

        serialized = inspect(attrs)

        refute serialized =~ @doc_text,
               "document text leaked into the artifact map (kind=#{inspect(overrides)}, banding=#{banding?})"

        # And the state body the instrument saw never appears either.
        refute serialized =~ "synthetic"
      end
    end
  end

  describe "contract errors and degradation" do
    test "a shadow observation never maps — it is a candidate, not evidence" do
      observation =
        record_observation(mode: :shadow, shadow_of: Ash.UUID.generate())

      assert_raise ArgumentError, ~r/shadow/, fn ->
        attrs_for(observation)
      end
    end

    test "an observation without a document hash examined nothing" do
      observation = record_observation(document_hash: nil)

      assert_raise ArgumentError, ~r/document/, fn ->
        attrs_for(observation)
      end
    end

    test "validate/1 checks keys against the actual EvidenceArtifact attribute set" do
      observation = record_observation([])
      attrs = attrs_for(observation)

      assert Evidence.validate(attrs) == :ok

      poisoned = Map.put(attrs, :document_text, @doc_text)

      assert {:error, {:unknown_attrs, [:document_text]}} = Evidence.validate(poisoned)
    end

    test "with the dependency off, the map still builds (pure) and validate degrades" do
      dir = ebin_dir!(AshCompliance)
      off!(AshCompliance, dir)

      observation = record_observation([])

      attrs = attrs_for(observation)

      assert attrs.method == :examine
      assert attrs.collector == "systemone:#{@digest}@0.7.5"

      assert {:error, {:missing_dependency, :ash_compliance}} = Evidence.validate(attrs)
      assert {:error, {:missing_dependency, :ash_compliance}} = Evidence.available?()

      on!(AshCompliance, dir)
    end

    test "missing required opts are a contract error, not a nil row" do
      observation = record_observation([])

      assert_raise KeyError, fn ->
        Evidence.artifact_attrs(observation, nil, organization_id: @org)
      end
    end
  end

  # The availability_off_test off!/on! pattern: remove the ebin from the
  # code path so the activation check honestly fails; restored by on!/2.
  defp off!(module, dir) do
    :code.purge(module)
    :code.delete(module)
    :code.del_path(dir)
  end

  defp on!(module, dir) do
    :code.add_path(dir)
    {:module, ^module} = Code.ensure_loaded(module)
  end

  defp ebin_dir!(module) do
    beam = Atom.to_charlist(module) ++ ~c".beam"

    case :code.where_is_file(beam) do
      :non_existing -> flunk("#{inspect(module)} beam not on the code path")
      full -> full |> List.to_string() |> Path.dirname() |> to_charlist()
    end
  end
end
