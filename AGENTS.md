# AGENTS.md

Guidance for AI agents working in this repository.

## Agent Tooling Mandate (opinionated)

This repo ships read-only Ash introspection tooling (`ash_agent_tools`, dev-only dep).
**Every agent session — you, reading this — must consult it BEFORE grepping source.**

- Before calling any Ash action or writing a changeset/query call: run
  `mix ash_agent.validate <Resource> <action> '<json-params>'` — it casts against the
  real contract and reports required/optional/unknown inputs with per-path errors.
- Before asking "what fields/actions/relationships does X have" or grepping a resource:
  `mix ash_agent.describe <Resource> [<action>]` (types, constraints, source locations).
- To find a symbol across the codebase: `mix ash_agent.search <term> [--kind K]`
  before ripgrep. Grep is the fallback, not the default.
- The deterministic iron-laws judge: `mix ash_agent.laws FILE [FILE...]` or
  `git diff main | mix ash_agent.laws - --diff` — it is wired into `mix precommit` and
  CI; treat a non-clean report as work the diff isn't done with.

Facts: stdout is pure JSON (parse it; don't eyeball); first invocation pays mix-boot
(~15s) — batch your questions. If a tool can't answer what you need, fall back to grep.

## Project guidelines

- Use `mix precommit` when you are done with all changes and fix any pending issues
  (compile warnings-as-errors, unlock check, format, iron-laws judge, tests, docs
  validation).
- This package is scaffold-only: module stubs name their ticket (AST-86…AST-95) in the
  moduledoc and ship **no feature logic** until that ticket lands. Don't grow a stub
  beyond its ticket.
- The package contract ("what it never does") is in the README and `usage-rules.md`; it
  is binding on every change: no model calls inside checks/FEEL/rules/projectors, no
  thresholds in config, no stored policy, no HTTP client/provider/answer-type code
  (upstream `ash_ai` + `req_llm` own the wire).
- Optional integrations (`ash_decisions`, `ash_rules`, `ash_bpmn`, `ash_compliance`,
  `ash_events`, `opentelemetry_ash`) must stay optional: gate behind
  `Code.ensure_loaded?/1`, degrade to `{:error, {:missing_dependency, dep}}`, never crash.
- Every source file carries its SPDX header; prose/dotfiles are annotated in REUSE.toml.
  `reuse lint` is a CI gate — keep it clean.
- Fixtures are synthetic. No customer data, contract terms, pricing, or private schema
  detail ever enters this repository.
- No novelty claims in prose; no product or customer names.

## Tests

- Run: `mix test`. The suite needs a PostgreSQL for the `:db`-tagged tests (env vars
  `DB_USER`, `DB_PASSWORD`, `DB_HOST`/`PGHOST`, `PGPORT`; the test helper creates and
  migrates its database itself). `SKIP_DB=1 mix test` excludes them.
- On the development host, use the `ash_enterprise` devenv (Postgres + toolchain):

  ```bash
  cd /home/lukegalea/ash_enterprise && devenv shell -- \
    bash -c 'cd /home/lukegalea/ast-forks/ash_judgments && mix test'
  ```

- The iron-laws judge and docs validation are dev-env steps (`ash_agent_tools` and
  `ex_doc` are dev-only): `MIX_ENV=dev mix deps.get` once, then `scripts/iron-laws.sh`
  and `scripts/extra-docs.sh` work standalone.
