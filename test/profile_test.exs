# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.ProfileTest do
  # The tests below mutate node-global Application env (profiles, region,
  # routes, policy) and one starts an inets httpd; not concurrent with
  # anything.
  use ExUnit.Case, async: false

  import AshJudgments.Profile, only: [new!: 1]
  import AshJudgments.Test.ProfileHelpers

  describe "the schema" do
    test "builds a valid local profile with defaults" do
      profile =
        new!(
          name: :laya_local,
          model: "laya:typed-decisions",
          base_url: {:system, "OLLAYA_BASE_URL"},
          api_key: {:system, "OLLAYA_API_KEY", "local"},
          residency: :in_cluster,
          region: :ca
        )

      assert profile.provider == :typesafe
      assert profile.receive_timeout == 30_000
      assert profile.pin == :optional
      assert profile.digest == nil
    end

    test "api_key accepts only {:system, _} — never a literal (AC-6)" do
      assert {:error, %ArgumentError{message: message}} =
               AshJudgments.Profile.new(
                 name: :bad,
                 model: "m",
                 api_key: "sk-super-secret",
                 residency: :in_cluster,
                 region: :ca
               )

      assert message =~ "api_key accepts only {:system, var}"
      assert message =~ "AC-6"
    end

    test "base_url accepts only {:system, _} or nil — never a literal endpoint" do
      assert {:error, %ArgumentError{}} =
               AshJudgments.Profile.new(
                 name: :bad,
                 model: "m",
                 base_url: "http://192.168.1.50:11435",
                 api_key: {:system, "OLLAYA_API_KEY"},
                 residency: :in_cluster,
                 region: :ca
               )
    end

    test "required fields and enum values are enforced" do
      assert {:error, %ArgumentError{message: message}} = AshJudgments.Profile.new(model: "m")
      assert message =~ "name"

      assert {:error, %ArgumentError{message: message}} =
               AshJudgments.Profile.new(
                 name: :bad,
                 model: "m",
                 api_key: {:system, "K"},
                 residency: :whatever,
                 region: :ca
               )

      assert message =~ "residency"

      assert {:error, %ArgumentError{message: message}} =
               AshJudgments.Profile.new(
                 name: :bad,
                 model: "m",
                 api_key: {:system, "K"},
                 residency: :in_cluster,
                 region: :mars
               )

      assert message =~ "region"
    end

    test "no api key literal appears in any config file (AC-6, the grep test)" do
      # Static: scan every committed config-ish source for an api_key set to
      # a string literal. `{:system, var}` references are the only accepted
      # shape, in this repository and in the docs examples.
      files =
        Path.wildcard("config/*.exs") ++
          Path.wildcard("*.exs") ++
          ["mix.exs", "README.md", "docs/instrument-profiles.md"]

      offenders =
        for path <- files,
            File.exists?(path),
            content = File.read!(path),
            match = Regex.run(~r/api_key:\s*"[^"]+"/, content),
            do: {path, match}

      assert offenders == []
    end
  end

  describe "model_spec/3 — the pin guard" do
    setup :configure_stack

    test "a floating alias under pin: :required raises FloatingAlias (AC-1)" do
      profile =
        new!(
          name: :jev_local,
          model: "jev-latest",
          base_url: {:system, "OLLAYA_BASE_URL"},
          api_key: {:system, "OLLAYA_API_KEY"},
          residency: :in_cluster,
          region: :ca,
          digest: "abc123",
          pin: :required
        )

      put_test_env(%{"OLLAYA_BASE_URL" => "http://127.0.0.1:11435", "OLLAYA_API_KEY" => "local"})

      assert_raise AshJudgments.Profile.FloatingAlias, ~r/floating alias/, fn ->
        AshJudgments.Profile.model_spec(profile)
      end
    end

    test "a -preview id is floating too, and an optional pin never raises" do
      preview =
        new!(
          name: :p,
          model: "winnow:preview",
          base_url: {:system, "OLLAYA_BASE_URL"},
          api_key: {:system, "K"},
          residency: :in_cluster,
          region: :ca,
          pin: :required,
          digest: "abc"
        )

      put_test_env(%{"K" => "local", "OLLAYA_BASE_URL" => "http://127.0.0.1:11435"})

      assert_raise AshJudgments.Profile.FloatingAlias, fn ->
        AshJudgments.Profile.model_spec(preview, %{}, %{tenant: :t})
      end

      optional = %{preview | pin: :optional}

      assert {:ok, %{id: "winnow:preview"}} = AshJudgments.Profile.model_spec(optional)
    end

    test "pin: :required without a digest raises MissingPin" do
      profile =
        new!(
          name: :unpinned,
          model: "winnow:e4b",
          base_url: {:system, "OLLAYA_BASE_URL"},
          api_key: {:system, "OLLAYA_API_KEY"},
          residency: :in_cluster,
          region: :ca,
          pin: :required
        )

      assert_raise AshJudgments.Profile.MissingPin, ~r/without a digest/, fn ->
        AshJudgments.Profile.model_spec(profile)
      end
    end
  end

  describe "model_spec/3 — the region guard" do
    setup :configure_stack

    test "an unconfigured stack region is a loud failure (law 10)" do
      Application.put_env(:ash_judgments, :region, nil)

      profile = local_profile()

      assert {:error, %AshJudgments.Profile.MissingRegion{}} =
               AshJudgments.Profile.model_spec(profile)
    end

    test "a profile pinned to another region is refused, naming both" do
      Application.put_env(:ash_judgments, :region, :us)

      profile = local_profile(region: :ca)

      assert {:error, %AshJudgments.Profile.RegionMismatch{} = error} =
               AshJudgments.Profile.model_spec(profile)

      assert error.profile_region == :ca
      assert error.stack_region == :us
    end

    test "a region match resolves to the inline spec; transport rides req_llm_opts" do
      Application.put_env(:ash_judgments, :region, :ca)
      put_test_env(%{"OLLAYA_BASE_URL" => "http://127.0.0.1:11435", "OLLAYA_API_KEY" => "local"})

      profile = local_profile()

      assert {:ok,
              %{provider: :typesafe, id: "winnow:e4b", capabilities: %{evaluate: true}} = spec} =
               AshJudgments.Profile.model_spec(profile)

      assert %{supported: true, family: "typesafe_systemone", path: "/v1/systemone"} =
               spec.execution.evaluate

      assert {:ok, opts} = AshJudgments.Profile.req_llm_opts(profile)
      assert opts[:base_url] == "http://127.0.0.1:11435"
      assert opts[:api_key] == "local"
      assert opts[:receive_timeout] == 30_000
    end

    test "a hosted profile resolves to the catalog string spec" do
      Application.put_env(:ash_judgments, :region, :ca)
      Application.put_env(:ash_judgments, :residency_policy, AshJudgments.Test.ResidencyPolicy)
      Application.put_env(:ash_judgments, :test_residency_decisions, %{sub_processor: true})

      put_test_env(%{"TYPESAFE_API_KEY" => "k"})

      assert {:ok, "typesafe:jev-1.13.0"} = AshJudgments.Profile.model_spec(hosted_profile())
    end
  end

  describe "model_spec/3 — the residency policy (the tenant opt-out)" do
    setup :configure_stack

    test "a denied sub_processor profile returns {:error, %ResidencyDenied{}} and no call is made (AC-2)" do
      Application.put_env(:ash_judgments, :region, :ca)
      Application.put_env(:ash_judgments, :residency_policy, AshJudgments.Test.ResidencyPolicy)
      Application.put_env(:ash_judgments, :test_residency_decisions, %{sub_processor: false})

      hosted = hosted_profile()

      # model_spec/3 is pure resolution: it performs no I/O of any kind, so
      # a denial is structurally zero calls. The contract suite is where
      # real calls happen, and it never sees this error path.
      assert {:error, %AshJudgments.Profile.ResidencyDenied{} = denied} =
               AshJudgments.Profile.model_spec(hosted, %{}, %{tenant: :acme, family: :coi})

      assert denied.profile_name == :hosted
      assert denied.residency == :sub_processor
      assert denied.family == :coi
      assert denied.tenant == :acme
      assert denied.policy == AshJudgments.Test.ResidencyPolicy
    end

    test "an allowed residency resolves (the policy permits it)" do
      Application.put_env(:ash_judgments, :region, :ca)
      Application.put_env(:ash_judgments, :residency_policy, AshJudgments.Test.ResidencyPolicy)
      Application.put_env(:ash_judgments, :test_residency_decisions, %{sub_processor: true})

      put_test_env(%{"TYPESAFE_API_KEY" => "from-env"})

      assert {:ok, "typesafe:jev-1.13.0"} =
               AshJudgments.Profile.model_spec(hosted_profile(), %{}, %{tenant: :acme})

      assert {:ok, opts} = AshJudgments.Profile.req_llm_opts(hosted_profile())
      assert opts[:api_key] == "from-env"
    end

    test "the default policy allows in_cluster and refuses sub_processor for unknown tenants" do
      Application.put_env(:ash_judgments, :region, :ca)
      Application.delete_env(:ash_judgments, :residency_policy)

      put_test_env(%{"OLLAYA_BASE_URL" => "http://127.0.0.1:11435", "OLLAYA_API_KEY" => "local"})

      assert {:ok, _} = AshJudgments.Profile.model_spec(local_profile(), %{}, %{tenant: :unknown})

      assert {:error, %AshJudgments.Profile.ResidencyDenied{}} =
               AshJudgments.Profile.model_spec(hosted_profile(), %{}, %{tenant: :unknown})
    end

    test "property: a sub_processor spec is returned only when allow?/3 is true (AC-3)" do
      # Exhaustive over the policy's whole decision space: both residencies
      # x both policy decisions x family present/absent — stronger than
      # random sampling for a 2x2x2 domain, and no new property-testing
      # dependency.
      Application.put_env(:ash_judgments, :region, :ca)
      Application.put_env(:ash_judgments, :residency_policy, AshJudgments.Test.ResidencyPolicy)

      put_test_env(%{"OLLAYA_BASE_URL" => "http://127.0.0.1:11435", "TYPESAFE_API_KEY" => "k"})

      for {residency, allowed?} <- [
            {:in_cluster, true},
            {:in_cluster, false},
            {:sub_processor, true},
            {:sub_processor, false}
          ],
          family <- [:coi, nil] do
        Application.put_env(:ash_judgments, :test_residency_decisions, %{
          in_cluster: allowed?,
          sub_processor: allowed?
        })

        profile =
          if residency == :in_cluster do
            local_profile()
          else
            hosted_profile()
          end

        result = AshJudgments.Profile.model_spec(profile, %{}, %{tenant: :t, family: family})
        policy_says = AshJudgments.Test.ResidencyPolicy.allow?(:t, residency, family)
        result_ok? = match?({:ok, _}, result)

        # The property: a spec escapes only past a permitting policy.
        assert result_ok? == policy_says,
               "residency #{inspect(residency)}, policy #{inspect(allowed?)}, family #{inspect(family)}: " <>
                 "got #{inspect(result)}"
      end
    end
  end

  describe "model_spec/3 — two-host routing (config, not code)" do
    setup :configure_stack

    test "a configured route map wins over the profile's own base_url" do
      Application.put_env(:ash_judgments, :region, :ca)

      put_test_env(%{
        "OLLAYA_BASE_URL" => "http://cpu:11435",
        "S1_OLLAYA_GPU_BASE_URL" => "http://gpu:11435",
        "OLLAYA_API_KEY" => "local"
      })

      Application.put_env(:ash_judgments, :model_routes, %{
        "winnow:e4b" => {:system, "S1_OLLAYA_GPU_BASE_URL"}
      })

      assert {:ok, %{id: "winnow:e4b"}} = AshJudgments.Profile.model_spec(local_profile())
      assert {:ok, opts} = AshJudgments.Profile.req_llm_opts(local_profile())
      assert opts[:base_url] == "http://gpu:11435"
    end

    test "a configured route map with no entry for the model fails loud, naming the model" do
      Application.put_env(:ash_judgments, :region, :ca)

      put_test_env(%{"OLLAYA_BASE_URL" => "http://cpu:11435", "OLLAYA_API_KEY" => "local"})
      Application.put_env(:ash_judgments, :model_routes, %{"other:model" => {:system, "X"}})

      assert {:error, %AshJudgments.Profile.RouteMissing{} = error} =
               AshJudgments.Profile.model_spec(local_profile())

      assert error.message =~ "winnow:e4b"
    end

    test "an unset route variable fails loud, naming the variable" do
      Application.put_env(:ash_judgments, :region, :ca)

      put_test_env(%{"OLLAYA_API_KEY" => "local"})
      Application.put_env(:ash_judgments, :model_routes, %{"winnow:e4b" => {:system, "NOT_SET"}})

      assert_raise AshJudgments.Profile.MissingEnv, ~r/NOT_SET/, fn ->
        AshJudgments.Profile.model_spec(local_profile())
      end
    end
  end

  describe "the registry and question resolution" do
    setup :configure_stack

    test "fetch/1 reads the configured registry; unknown names error with the name" do
      Application.put_env(:ash_judgments, :region, :ca)

      Application.put_env(:ash_judgments, :profiles, [
        [
          name: :laya_local,
          model: "laya:typed-decisions",
          base_url: {:system, "OLLAYA_BASE_URL"},
          api_key: {:system, "OLLAYA_API_KEY", "local"},
          residency: :in_cluster,
          region: :ca
        ]
      ])

      assert {:ok, %AshJudgments.Profile{name: :laya_local}} =
               AshJudgments.Profile.fetch(:laya_local)

      assert {:error, %AshJudgments.Profile.ProfileNotFound{} = error} =
               AshJudgments.Profile.fetch(:nope)

      assert error.message =~ ":nope"
    end

    test "a question map resolves its profile by name and carries the family" do
      Application.put_env(:ash_judgments, :region, :ca)
      Application.put_env(:ash_judgments, :residency_policy, AshJudgments.Test.ResidencyPolicy)
      Application.put_env(:ash_judgments, :test_residency_decisions, %{sub_processor: false})

      Application.put_env(:ash_judgments, :profiles, [
        [
          name: :hosted,
          model: "jev-1.13.0",
          api_key: {:system, "TYPESAFE_API_KEY"},
          residency: :sub_processor,
          region: :ca
        ]
      ])

      question = %{profile: :hosted, family: :coi}

      assert {:error, %AshJudgments.Profile.ResidencyDenied{family: :coi}} =
               AshJudgments.Profile.model_spec(question, %{}, %{tenant: :acme})
    end
  end

  describe "digest pinning" do
    setup do
      # A real local HTTP server (OTP inets, no new dependency) speaking the
      # runtime's model-listing shape.
      Application.put_env(:ash_judgments, :region, :ca)
      put_test_env(%{"OLLAYA_API_KEY" => "local"})

      base =
        AshJudgments.Test.DigestServer.start(%{
          "models" => [
            %{
              "name" => "winnow:e4b",
              "digest" => "aa11bb22cc33",
              "expires_at" => "2026-12-01T00:00:00Z"
            }
          ]
        })

      on_exit(fn -> Application.delete_env(:ash_judgments, :model_routes) end)

      %{base: base, digest: "aa11bb22cc33"}
    end

    test "fetch/1 reads the digest from the listing endpoint", %{base: base, digest: digest} do
      profile = local_profile(base_url: {:system, "PROBE_BASE_URL"}, digest: digest)
      put_test_env(%{"PROBE_BASE_URL" => base})

      assert {:ok, ^digest} = AshJudgments.Profile.Digest.fetch(profile)
    end

    test "a matching pin passes prefix-wise; a mismatch names both digests (AC-4)", %{
      base: base,
      digest: digest
    } do
      profile = local_profile(base_url: {:system, "PROBE_BASE_URL"}, digest: digest)
      put_test_env(%{"PROBE_BASE_URL" => base})

      # The runtime may report a short prefix; the profile may pin the full sha256.
      full = digest <> String.duplicate("d", 52)
      assert AshJudgments.Profile.Digest.digest_match?(full, digest)

      refute AshJudgments.Profile.Digest.digest_match?(
               full,
               "ff" <> String.slice(digest, 2..-1//1)
             )

      assert :ok = AshJudgments.Profile.Digest.verify(profile, digest)
      assert :ok = AshJudgments.Profile.warm(profile)

      wrong = %{profile | digest: "ee" <> String.slice(digest, 2..-1//1)}

      assert {:error, %AshJudgments.Profile.DigestMismatch{} = mismatch} =
               AshJudgments.Profile.warm(wrong)

      assert mismatch.expected == wrong.digest
      assert mismatch.reported == digest
      assert mismatch.message =~ wrong.digest
      assert mismatch.message =~ digest
    end

    test "warm/1 fails loud on an unreachable runtime" do
      profile =
        local_profile(
          base_url: {:system, "PROBE_BASE_URL"},
          digest: "aa11bb22cc33",
          receive_timeout: 500
        )

      put_test_env(%{"PROBE_BASE_URL" => "http://127.0.0.1:1"})

      assert {:error, %AshJudgments.Profile.DigestUnavailable{}} =
               AshJudgments.Profile.warm(profile)
    end
  end
end
