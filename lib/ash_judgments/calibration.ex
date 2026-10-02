# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Calibration do
  @moduledoc """
  Calibration — **ticket AST-91** (CORE-CALIB).

  Law 5: thresholds are policy data, earned by calibration. A band table may
  not publish for a family without a calibration run above a minimum n. A
  `CalibrationRun` per (family, model version, eval-set hash) holds
  reliability bins, ECE, Brier, per-class precision and recall, and n; its
  output is a *proposed* DMN triage table version — a proposal carries
  lineage, never applies in serving, and re-earns calibration on data it
  never saw.

  ## Scope (AST-91)

  - A `CalibrationRun` fragment and resource definition for the host:
    identity, sample sizes, calibration metrics, the selective curve
    (coverage vs accuracy), conformal thresholds at target risk with a cost
    matrix, and provenance (`:eval_set` | `:shadow_ledger`).
  - `mix ash_judgments.calibrate --family F --eval-set PATH --profile P`:
    run, compute, record, and write the proposed band table as DMN XML.
  - A publish-time verifier (modelled on the ash_decisions publish verifier):
    no publish for a family without a calibration run above the minimum n.

  TODO(AST-91): everything above. This module is a scaffold stub — no
  feature logic ships until the ticket lands.
  """
end
