# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

%{
  configs: [
    %{
      name: "default",
      strict: true,
      merge_with_default_config: true,
      # The ash_credo plugin: Ash-aware checks over the DSL state, plus the
      # run-scoped cache. Checks that introspect compiled modules need
      # `mix compile` first — CI orders credo after compile for that reason.
      plugins: [{AshCredo, []}],
      checks: %{
        disabled: [
          # The house style favours fully-qualified calls into Ash's Info
          # modules and cross-module helpers — they are grep-friendly and
          # keep the called surface obvious at each site, so single-use
          # "alias this nested module" suggestions are noise.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
