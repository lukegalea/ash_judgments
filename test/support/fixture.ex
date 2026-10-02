# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.Fixture do
  @moduledoc """
  The ReqLLM fixture helper for the test suite.

  Upstream `evaluate` accepts `:req_llm_opts`, and ReqLLM's `:fixture` step
  (`ReqLLM.Step.Fixture`) replays recorded provider exchanges instead of
  calling a model: pass a fixture name (or `{provider, name}`), and the
  request is answered from the recording. That is what lets the later CORE
  tickets test the *plumbing* — profile resolution, question casting,
  ledger recording — with no model on the path and no network, and it is the
  same record-don't-recompute discipline the package imposes on everyone
  else.

  Note this replays recorded *exchanges*, not judgment semantics: fixtures
  never substitute for calibration or labelled eval sets. They are CI
  determinism, not evidence.

  TODO(AST-89): the ledger-backed replay mode is the durable mechanism;
  fixtures are the test-level stopgap.
  """

  @doc """
  Req options wiring a named fixture into an `evaluate` call, suitable as
  the `:req_llm_opts` argument upstream accepts.

      AshJudgments.Test.Fixture.req_llm_opts("triage_noul")
      #=> [fixture: "triage_noul"]

      AshJudgments.Test.Fixture.req_llm_opts({"typesafe", "choice_matrix"})
      #=> [fixture: {"typesafe", "choice_matrix"}]
  """
  @spec req_llm_opts(String.t() | {atom(), String.t()}) :: keyword()
  def req_llm_opts(name_or_tuple) do
    [fixture: name_or_tuple]
  end
end
