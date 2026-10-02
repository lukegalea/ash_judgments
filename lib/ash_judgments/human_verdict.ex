# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.HumanVerdict do
  @moduledoc """
  The human verdict record — **ticket AST-88** (CORE-LEDGER, RFC §7.3).

  A human verdict is the observation's correction or confirmation: who
  reviewed, what they saw, what they decided. Verdicts are the eval and
  fine-tune corpus, and the reviewer is the author of record (law: the
  human who activates decides).

  The package supplies `AshJudgments.HumanVerdict.Fragment`; the host
  includes it in a resource on its own platform base, exactly like
  `AshJudgments.Ledger.Fragment`. The `:record` create accepts every
  field as input — the reviewer is an INPUT (replay-safe; the host's
  policies decide who may claim which reviewer identity, never this
  package).

  `note` is the one payload-class field (a reviewer's free text can quote
  a document) — outside `record_hash`, erasable. Everything else is
  envelope-class: digests, codes and ids.
  """

  @moduledoc since: "0.1.0"
end
