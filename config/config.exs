# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

# The package ships no runtime configuration of its own: it never holds
# thresholds, policy or provider settings in config (that is a hard
# "never does" of the package contract). The only configuration here is
# test-only, for the sandboxed TestRepo behind the test support app.
import Config

if config_env() == :test do
  import_config "test.exs"
end
