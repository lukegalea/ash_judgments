# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT
defmodule AshJudgments.A2ui do
  @moduledoc """
  The judgment surfaces: A2UI screens over a host's fragment-built
  resources, so a person can settle the work the loop leaves for them.

  Each surface is a macro a host binds to its own resource in its web
  layer. It expands to an `AshA2ui.Standalone` module, so the host's
  domain layer never depends on `ash_a2ui`, which is an optional
  dependency of this package.

  ```elixir
  defmodule MyAppWeb.A2ui.VerdictsUI do
    use AshJudgments.A2ui.Verdicts, resource: MyApp.SystemOne.Banding
  end
  ```

  | Surface | Bound to | Reads | Acts |
  |---|---|---|---|
  | `AshJudgments.A2ui.Verdicts` | the banding resource | `:awaiting_verdict` | `:record_verdict` |
  | `AshJudgments.A2ui.BandTables` | the calibration-run resource | `:awaiting_certification` | `:certify_and_publish` |
  | `AshJudgments.A2ui.Certifications` | the certification resource | `:certified` | `:revoke` |
  | `AshJudgments.A2ui.Calibration` | the calibration-run resource | `:read` | none |
  | `AshJudgments.A2ui.Facts` | the facts resource | `:current` | none |

  **Every act is an action on the host's resource, under the host's
  policies.** A surface only names the reads and actions in its contract,
  and `ash_a2ui`'s verifiers check them against the bound resource when
  the host compiles, so a missing one is a compile error, not a broken
  button. Each surface's moduledoc gives its contract. Where the work is
  the package's own, the package supplies the implementation the host's
  action runs (`AshJudgments.HumanVerdict.FromBanding`). Where a read
  crosses two host resources, or the act reaches host machinery (saving
  and publishing a band table), the host writes it.

  Every macro takes `:resource` (required), `:surface_id` and `:title`,
  and the names of the read and the actions it uses, for a host whose
  names differ.
  """
  @moduledoc since: "0.3.3"

  @doc false
  def option!(opts, key, default), do: Keyword.get(opts, key, default)
end
