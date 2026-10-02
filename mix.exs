# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description """
  The System One judgment substrate for Ash: declared, typed, calibrated
  questions over any subject resource, a provenance-carrying judgment ledger,
  and the bridges that turn recorded judgments into DMN inputs, rule facts and
  process signals. Transport is upstream `ash_ai` evaluate over ReqLLM — this
  package ships no HTTP client, provider or answer types.
  """

  def project do
    [
      app: :ash_judgments,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      package: package(),
      source_url: "https://github.com/lukegalea/ash_judgments",
      docs: docs(),

      # Non-gating in CI (ADR 0007: Dialyzer against Spark-generated shapes
      # produces findings nobody has canonical guidance for; the 1.18+ type
      # checker in `mix compile --warnings-as-errors` is this repository's
      # real static-analysis gate).
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # No supervision tree: the scaffold owns no processes. The cache and
  # telemetry tickets (AST-89/AST-90) add event handlers, not workers; if a
  # process ever becomes genuinely necessary it gets a named child_spec here
  # with a comment saying why.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Compile the test support app (a minimal domain + resources on Postgres,
  # used by the `:db` tests) only under :test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core: the declaration substrate and the upstream call this package
      # builds on. Transport (HTTP client, provider, answer types) is owned
      # by ash_ai + req_llm — this package deliberately ships none.
      {:ash, "~> 3.33"},
      {:ash_ai, "~> 1.1"},
      {:req_llm, "~> 1.24"},
      {:spark, "~> 2.2"},

      # Canonical-JSON helpers (the cache key and the availability report's
      # JSON-encodability contract). Declared explicitly rather than riding
      # transitively on ash.
      {:jason, "~> 1.4"},

      # The ONE outbound call this package makes: the runtime's
      # model-listing endpoint, for digest pinning
      # (AshJudgments.Profile.Digest — see its scope-boundary note). The
      # evaluate wire itself stays upstream (ash_ai + req_llm, which bring
      # req along transitively anyway); declared explicitly because it is
      # called directly.
      {:req, "~> 0.5"},

      # Optional concept integrations. Hosts add the dep, the bridge
      # activates (see AshJudgments.Availability); a missing dep degrades to
      # a structured error that names it (`{:error, {:missing_dependency,
      # :ash_rules}}`), never a crash. All are gated behind
      # `Code.ensure_loaded?/1` conditional compilation (the Ecto-Jason
      # pattern), so this package compiles cleanly with or without any of
      # them.
      #
      # First-party packages not yet on hex ship as GitHub deps, per house
      # convention (see ash_agent_tools, which declares the same four this
      # way).
      # Unpinned github dep (matches ash_compliance's requirement — the
      # lock file pins the resolved SHA, which carries the S1-54 set
      # evaluator that AST-93's equivalence cross-check builds on).
      {:ash_rules, github: "lukegalea/ash_rules", optional: true},
      {:ash_compliance, github: "lukegalea/ash_compliance", optional: true},
      {:ash_bpmn, github: "lukegalea/ash_bpmn", optional: true},
      # The engine resource verifiers' policy checks want a SAT solver at
      # compile time; without one they warn, which is fatal under
      # --warnings-as-errors. Dev/test-only, like the engine itself.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:ash_decisions, github: "lukegalea/ash_decisions", optional: true},
      {:ash_events, "~> 0.7", optional: true},
      {:opentelemetry_ash, "~> 0.1", optional: true},

      # The test support app persists its resources on a real PostgreSQL
      # (sandboxed TestRepo, :db-tagged tests, SKIP_DB=1 to exclude).
      # `optional:` rather than `only: :test` — a first-party dep in the
      # graph (ash_events_projections, via the optional concept packages)
      # requires ash_postgres unconditionally, so a test-only restriction
      # cannot converge. `optional:` keeps it out of consumers' dependency
      # graphs all the same. (Same resolution as ash_agent_tools.)
      {:ash_postgres, "~> 2.13", optional: true},

      # Dev-and-test-only: the laws judge (`mix ash_agent.laws`) and the Ash
      # introspection mandate in AGENTS.md ride on ash_agent_tools — and the
      # test env gets `mix ash_agent.describe` over the test support
      # resources (the registry's section-surfacing check, AST-87/AC-6).
      # runtime: false and the hex package `files:` keep it out of
      # consumers' graphs either way.
      {:ash_agent_tools,
       github: "lukegalea/ash_agent_tools", only: [:dev, :test], runtime: false},

      # Dev hygiene: static analysis (credo with the ash_credo plugin), type
      # checking, docs.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.18", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/lukegalea/ash_judgments",
        "Usage rules" => "https://github.com/lukegalea/ash_judgments/blob/HEAD/usage-rules.md"
      },
      files: ~w(lib mix.exs README.md LICENSE LICENSES usage-rules.md docs .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras:
        [
          "README.md",
          "usage-rules.md",
          "docs/instrument-profiles.md",
          "docs/question-registry.md",
          "docs/bridge-bpmn.md",
          "docs/bridge-evidence.md"
        ] ++ extra_docs()
    ]
  end

  # EXTRA_DOCS=AGENTS.md mix docs routes standalone agent docs through the
  # extras pipeline so broken refs warn like any other doc. The value is a
  # single Path.wildcard glob; CI sets it (the ex_doc#2272 pattern, same as
  # ash_agent_tools).
  defp extra_docs do
    if glob = System.get_env("EXTRA_DOCS"), do: Path.wildcard(glob), else: []
  end

  defp aliases do
    [
      # The house pre-commit gate, mirroring ash_enterprise's. The iron-laws
      # judge and the docs validation run last and set their own MIX_ENV=dev
      # internally, because ash_agent_tools and ex_doc are dev-only deps.
      # See scripts/iron-laws.sh and scripts/extra-docs.sh.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "cmd scripts/iron-laws.sh",
        "test",
        "cmd scripts/extra-docs.sh"
      ]
    ]
  end
end
