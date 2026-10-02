# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Profile.FloatingAlias do
  @moduledoc """
  A profile pinned `:required` resolved to a floating model id (`-latest`,
  `-preview`). Law 6: a floating tag is a silent policy change and is
  forbidden in compliance paths. Raised, not returned — a pin requirement
  that resolves to an alias is profile misconfiguration, not a runtime
  condition.
  """

  defexception [:model, :message]

  @type t :: %__MODULE__{
          model: String.t(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    model = Keyword.fetch!(opts, :model)

    %__MODULE__{
      model: model,
      message:
        "profile model #{inspect(model)} is a floating alias; floating tags are forbidden where pin: :required (law 6). Pin an explicit version id and digest"
    }
  end
end

defmodule AshJudgments.Profile.MissingPin do
  @moduledoc """
  A profile pinned `:required` declares no `digest`. A profile that cannot
  report a digest cannot feed admission (RFC S1-24 §5.3, ADR 0040); the
  profile fails to resolve instead of quietly producing unpinned rows.
  Raised, like `FloatingAlias`.
  """

  defexception [:profile_name, :message]

  @type t :: %__MODULE__{
          profile_name: atom() | String.t(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :profile_name)

    %__MODULE__{
      profile_name: name,
      message:
        "profile #{inspect(name)} declares pin: :required without a digest; set digest: (sha256 as the runtime reports it) or downgrade pin: to :optional for non-compliance families"
    }
  end
end

defmodule AshJudgments.Profile.MissingRegion do
  @moduledoc """
  The running stack has no `config :ash_judgments, :region` set, so the
  region guard cannot run. Failing loud here is deliberate (ops posture):
  a total that quietly covers one region is the most common data error
  (law 10); a host that has not declared its region must not resolve
  instruments at all.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}

  @impl true
  def exception(_opts) do
    %__MODULE__{
      message:
        "no stack region configured; set config :ash_judgments, :region, :ca | :us so the region guard can run (law 10)"
    }
  end
end

defmodule AshJudgments.Profile.RegionMismatch do
  @moduledoc """
  A profile whose `region` differs from the running stack's configured
  region. The profile is refused, never silently crossed.
  """

  defexception [:profile_name, :profile_region, :stack_region, :message]

  @type t :: %__MODULE__{
          profile_name: atom() | String.t(),
          profile_region: AshJudgments.Profile.region(),
          stack_region: AshJudgments.Profile.region(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :profile_name)
    profile_region = Keyword.fetch!(opts, :profile_region)
    stack_region = Keyword.fetch!(opts, :stack_region)

    %__MODULE__{
      profile_name: name,
      profile_region: profile_region,
      stack_region: stack_region,
      message:
        "profile #{inspect(name)} is pinned to region #{inspect(profile_region)} but this stack runs #{inspect(stack_region)}; the profile is refused (law 10)"
    }
  end
end

defmodule AshJudgments.Profile.ResidencyDenied do
  @moduledoc """
  The host `ResidencyPolicy` refused this profile's residency for the
  tenant (a tenant opt-out, per ADR 0026). Returned as
  `{:error, %ResidencyDenied{}}` — it is a data/authorization condition,
  not a misconfiguration — and it is enforced in the action path, next to
  the client, never inside a policy check (law 3).
  """

  defexception [:profile_name, :residency, :family, :tenant, :policy, :message]

  @type t :: %__MODULE__{
          profile_name: atom() | String.t(),
          residency: AshJudgments.Profile.residency(),
          family: atom() | nil,
          tenant: term(),
          policy: module() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    %__MODULE__{
      profile_name: Keyword.fetch!(opts, :profile_name),
      residency: Keyword.fetch!(opts, :residency),
      family: Keyword.get(opts, :family),
      tenant: Keyword.get(opts, :tenant),
      policy: Keyword.fetch!(opts, :policy),
      message:
        "residency #{inspect(Keyword.fetch!(opts, :residency))} denied for profile #{inspect(Keyword.fetch!(opts, :profile_name))} by #{inspect(Keyword.fetch!(opts, :policy))}.allow?/3" <>
          maybe_family(Keyword.get(opts, :family))
    }
  end

  defp maybe_family(nil), do: ""
  defp maybe_family(family), do: " (family #{inspect(family)})"
end

defmodule AshJudgments.Profile.UnsupportedProvider do
  @moduledoc """
  The profile's provider has no wire contract this package can resolve
  inline specs for. The wire table is data in `AshJudgments.Profile`
  (the `:typesafe` wire the in-zone runtimes speak); adding a provider
  means adding its wire contract there — never model code.
  """

  defexception [:provider, :message]

  @type t :: %__MODULE__{
          provider: atom(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    provider = Keyword.fetch!(opts, :provider)

    %__MODULE__{
      provider: provider,
      message:
        "no wire contract for provider #{inspect(provider)}; AshJudgments.Profile resolves inline specs for the providers in its @wire_contracts table"
    }
  end
end

defmodule AshJudgments.Profile.MissingEnv do
  @moduledoc """
  A `{:system, var}` reference on the profile (or on a configured route)
  resolved to an unset environment variable. Never a silent empty string:
  the resolution fails naming the variable and the profile.
  """

  defexception [:var, :profile_name, :message]

  @type t :: %__MODULE__{
          var: String.t(),
          profile_name: atom() | String.t(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    var = Keyword.fetch!(opts, :var)
    name = Keyword.fetch!(opts, :profile_name)

    %__MODULE__{
      var: var,
      profile_name: name,
      message:
        "environment variable #{inspect(var)} (needed by profile #{inspect(name)}) is not set"
    }
  end
end

defmodule AshJudgments.Profile.RouteMissing do
  @moduledoc """
  The `config :ash_judgments, :model_routes` map is configured but has no
  entry for the profile's model. Mirrors the clinic-demo spike's resolver
  semantics: when a route map is in play, every model must route
  explicitly — a result must never lie about which host answered.
  """

  defexception [:model, :message]

  @type t :: %__MODULE__{
          model: String.t(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    model = Keyword.fetch!(opts, :model)

    %__MODULE__{
      model: model,
      message:
        "config :ash_judgments, :model_routes is set but has no entry for #{inspect(model)}; add one (model => {:system, var}) or unset the map for single-host routing"
    }
  end
end

defmodule AshJudgments.Profile.ProfileNotFound do
  @moduledoc """
  No configured profile under this name. Profiles are host config
  (`config :ash_judgments, :profiles`); a missing name is a resolution
  error naming what was looked for.
  """

  defexception [:name, :message]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :name)

    %__MODULE__{
      name: name,
      message:
        "no instrument profile named #{inspect(name)} in config :ash_judgments, :profiles (see AshJudgments.Profile.registry/0)"
    }
  end
end

defmodule AshJudgments.Profile.DigestUnavailable do
  @moduledoc """
  The runtime's model-listing endpoint did not yield a digest for the
  profile's model — unreachable, unexpected shape, or the model is not
  loaded. A pinned profile cannot be warmed or contract-tested past this.
  """

  defexception [:profile_name, :endpoint, :reason, :message]

  @type t :: %__MODULE__{
          profile_name: atom() | String.t(),
          endpoint: String.t(),
          reason: term(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :profile_name)
    endpoint = Keyword.fetch!(opts, :endpoint)
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      profile_name: name,
      endpoint: endpoint,
      reason: reason,
      message:
        "could not read a model digest for profile #{inspect(name)} from #{endpoint}" <>
          if(reason, do: " (#{inspect(reason)})", else: "")
    }
  end
end

defmodule AshJudgments.Profile.DigestMismatch do
  @moduledoc """
  The digest the runtime reports does not match the profile's configured
  pin. Both values are carried — the failure must be able to name them
  (CORE-PROFILES/AC-4) — and a warm-up or contract run fails on this.
  """

  defexception [:profile_name, :expected, :reported, :message]

  @type t :: %__MODULE__{
          profile_name: atom() | String.t(),
          expected: String.t(),
          reported: String.t() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :profile_name)
    expected = Keyword.fetch!(opts, :expected)
    reported = Keyword.fetch!(opts, :reported)

    %__MODULE__{
      profile_name: name,
      expected: expected,
      reported: reported,
      message:
        "digest mismatch for profile #{inspect(name)}: profile pins #{expected}, runtime reports #{reported}"
    }
  end
end
