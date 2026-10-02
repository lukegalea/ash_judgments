# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.InstrumentContractTest do
  @moduledoc """
  The dual contract test (CORE-PROFILES): all four answer kinds — Noul,
  Choice, Score, Judgments — against each configured instrument, over the
  real wire, through the same profile resolution production uses.

  Excluded from every ordinary run; run it on a host that can reach the
  instrument:

      OLLAYA_BASE_URL=http://<host>:11435 \\
      OLLAYA_MODEL="laya:typed-decisions" \\
      OLLAYA_DIGEST=<optional expected sha256> \\
      mix test --only instrument_contract

  Jobs:

  - **Local** — runs when `OLLAYA_BASE_URL` is set. `OLLAYA_MODEL` names
    the model (deliberately required: the architecture is model-agnostic
    and the homelab models are prototype instruments, so nothing here
    defaults one). `OLLAYA_DIGEST`, when set, is the pin AC-4 verifies —
    a mismatch fails the suite naming both digests.
  - **Hosted** — runs when `TYPESAFE_API_KEY` is set. Opt-in, never on
    pull requests from forks (the CI job is workflow_dispatch-only), and
    dormant under the operator's DEC-HOSTED decision: hosted is never an
    instrument. The job exists because the *wire* contract is worth
    pinning if that posture ever changes, and because a dormant test that
    is wrong is worse than none.

  The suite records the model version that answered (via upstream's
  `AshAi.Actions.Result`) and, for pinned profiles, verifies the runtime's
  reported digest.
  """

  use ExUnit.Case, async: false

  import AshJudgments.Test.ProfileHelpers

  @moduletag :instrument_contract

  @probe_text "The resident slipped on the ward floor during the night shift; a carer witnessed it."
  # Synthetic probe text; nothing customer-related ships as a fixture.

  setup context do
    Application.put_env(:ash_judgments, :region, :ca)
    Application.delete_env(:ash_judgments, :model_routes)

    profile =
      if context[:hosted] do
        hosted_contract_profile()
      else
        local_contract_profile()
      end

    %{profile: profile}
  end

  describe "local instrument (OLLAYA_BASE_URL)" do
    @describetag local: true

    setup context do
      assert base_url = System.get_env("OLLAYA_BASE_URL"),
             "set OLLAYA_BASE_URL to run the local instrument contract job"

      put_test_env(%{
        "OLLAYA_BASE_URL" => base_url,
        "OLLAYA_API_KEY" => System.get_env("OLLAYA_API_KEY", "local")
      })

      {:ok, %{profile: AshJudgments.Profile.new!(profile_attrs(context.profile, base_url))}}
    end

    test "noul casts against the profile", %{profile: profile} do
      assert %{result: %AshAi.Evaluate.Noul{probability: p}, model: model} =
               run_probe(:noul, profile)

      assert is_float(p) and p >= 0.0 and p <= 1.0
      assert is_binary(model) and model != ""
    end

    test "choice casts against the profile", %{profile: profile} do
      assert %{result: %AshAi.Evaluate.Choice{} = choice, model: model} =
               run_probe(:choice, profile)

      assert choice.value in [:supports, :contradicts, :insufficient]
      assert is_map(choice.probabilities)
      assert is_float(choice.confidence)
      assert is_binary(model) and model != ""
    end

    test "score casts against the profile", %{profile: profile} do
      assert %{result: %AshAi.Evaluate.Score{} = score, model: model} =
               run_probe(:score, profile)

      assert score.level in ["Routine", "Time-sensitive", "Urgent"]
      assert is_float(score.value)
      assert is_map(score.probabilities)
      assert is_binary(model) and model != ""
    end

    test "judgments casts against the profile", %{profile: profile} do
      assert %{result: %{fall: %AshAi.Evaluate.Noul{}, disposition: %AshAi.Evaluate.Choice{}}} =
               run_probe(:judgments, profile)
    end

    test "the pinned digest matches the runtime's (AC-4)", %{profile: profile} do
      # AC-4: the digest matches `digest:` or the suite fails naming both.
      if profile.digest do
        assert {:ok, reported} = AshJudgments.Profile.Digest.fetch(profile)
        assert :ok = AshJudgments.Profile.Digest.verify(profile, reported)
      else
        # No OLLAYA_DIGEST configured: still report what the runtime says,
        # so the run log carries the digest to pin.
        case AshJudgments.Profile.Digest.fetch(profile) do
          {:ok, reported} ->
            IO.puts(
              "instrument contract: runtime reports digest #{reported} for #{profile.model} — pin it with OLLAYA_DIGEST"
            )

          {:error, error} ->
            flunk(
              "runtime digest unavailable (set OLLAYA_DIGEST to skip pinning): #{Exception.message(error)}"
            )
        end
      end
    end
  end

  describe "hosted instrument (TYPESAFE_API_KEY) — opt-in" do
    @describetag hosted: true

    setup context do
      assert api_key = System.get_env("TYPESAFE_API_KEY"),
             "set TYPESAFE_API_KEY to run the hosted instrument contract job"

      put_test_env(%{"TYPESAFE_API_KEY" => api_key})

      # The pinned id the ticket names. Test data, not architecture: the
      # id rides the environment like every other model choice.
      model = System.get_env("TYPESAFE_MODEL", "jev-1.13.0")
      {:ok, %{profile: AshJudgments.Profile.new!(profile_attrs(context.profile, nil, model))}}
    end

    test "noul casts against the hosted wire", %{profile: profile} do
      assert %{result: %AshAi.Evaluate.Noul{probability: p}, model: model} =
               run_probe(:noul, profile)

      assert is_float(p) and p >= 0.0 and p <= 1.0
      assert is_binary(model) and model != ""
    end

    test "choice, score and judgments cast against the hosted wire", %{profile: profile} do
      assert %{result: %AshAi.Evaluate.Choice{}} = run_probe(:choice, profile)
      assert %{result: %AshAi.Evaluate.Score{}} = run_probe(:score, profile)
      assert %{result: %{fall: %AshAi.Evaluate.Noul{}}} = run_probe(:judgments, profile)
    end
  end

  defp local_contract_profile do
    %AshJudgments.Profile{name: :contract_local, residency: :in_cluster, region: :ca}
  end

  defp hosted_contract_profile do
    %AshJudgments.Profile{name: :contract_hosted, residency: :sub_processor, region: :ca}
  end

  # The runtime profile attrs, from the environment: the model is required
  # (no default model lives in this repository), the digest optional.
  defp profile_attrs(skeleton, base_url, model \\ nil) do
    model =
      model || System.get_env("OLLAYA_MODEL") ||
        flunk!(
          "set OLLAYA_MODEL to run the local instrument contract job (the package pins no default model)"
        )

    [
      name: skeleton.name,
      model: model,
      base_url: (base_url && {:system, "OLLAYA_BASE_URL"}) || nil,
      api_key: {:system, (base_url && "OLLAYA_API_KEY") || "TYPESAFE_API_KEY"},
      residency: skeleton.residency,
      region: skeleton.region,
      digest: System.get_env("OLLAYA_DIGEST"),
      pin: (System.get_env("OLLAYA_DIGEST") && :required) || :optional
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp run_probe(action, profile) do
    AshJudgments.Test.InstrumentProbe
    |> Ash.ActionInput.for_action(action, %{text: @probe_text})
    |> Ash.run_action!(context: %{instrument_probe: %{profile: profile}})
  end

  defp flunk!(message), do: raise(ExUnit.AssertionError, message: message)
end
