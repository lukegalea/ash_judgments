# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Banding do
  @moduledoc """
  The banding and band-table-certification records — **ticket AST-92**
  (CORE-BRIDGE-DMN), RFC §7.1 and §8.2.

  A **banding** says which band-table row an observation's answer fell
  into. It asserts nothing about the world and admits nothing — the
  admission (a separate host decision) is what turns a banding into a
  fact, a review task, or nothing. A **certification** records that a
  band-table definition is fit for a family: the judgment-side half of
  §8.2; activation itself stays `ash_decisions`' lifecycle.

  Both are host-included fragments (`AshJudgments.Banding.Fragment`,
  `AshJudgments.Banding.CertificationFragment`) on the host's own
  platform base — the host's AshEvents audit, tenancy and policies
  apply. Both creates accept every field as input, including the
  band-table's own outputs (`{band, matched_rule_ids, fact_value}`) —
  the banding is RECORDED, never recomputed from probabilities (law 2,
  RFC §6.1: the band-table evaluation happens before the create, and its
  evaluation id is passed in).
  """

  @moduledoc since: "0.1.0"
end
