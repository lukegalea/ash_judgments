# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Profile do
  @moduledoc """
  Instrument profiles — **ticket AST-86** (CORE-PROFILES).

  A profile treats a model as four separable concerns, none of them
  hardcoded:

  - **identity** — the model id plus, when `pin: :required`, the sha256
    digest the runtime must report (RFC S1-24 §5.3/Q7: a model tag is never
    enough; a profile that cannot report a digest cannot feed admission);
  - **runtime/transport** — a ReqLLM model spec for upstream `evaluate/2`
    (a full inline spec for an in-zone runtime, a catalog string for a
    hosted one; see `model_spec/3`). No HTTP client and no provider
    behaviour ship here: the wire is upstream `ash_ai` + `req_llm`;
  - **residency class** — `:in_cluster | :sub_processor` and a region,
    guarded against the running stack's configured region (law 10);
  - **replacement** — profiles are swappable data declared in host config
    (`config :ash_judgments, :profiles`), never code. The homelab models
    are prototype instruments; models are re-chosen at launch, so nothing
    model-specific may live in this package.

  ## Declaring profiles

      config :ash_judgments,
        region: :ca,
        profiles: [
          [
            name: :laya_local,
            model: "laya:typed-decisions",
            base_url: {:system, "OLLAYA_BASE_URL"},
            api_key: {:system, "OLLAYA_API_KEY", "local"},
            residency: :in_cluster,
            region: :ca,
            digest: {:system, "OLLAYA_LAYA_DIGEST"},
            pin: :required
          ]
        ]

    `{:system, var}` references resolve at call time, never at boot, so a
    release can be repointed without a rebuild. `api_key` accepts only
    `{:system, _}` — never a literal (AC-6). `digest` also accepts
    `{:system, var}`; it is read when the profile is pinned or warmed.

  Two-host routing (which model answers from which host) is **config, not
  code**: set `config :ash_judgments, :model_routes, %{"winnow:e4b" =>
  {:system, "S1_OLLAYA_GPU_BASE_URL"}}` and resolution picks the entry for
  the profile's model. Mirroring the clinic-demo spike's resolver
  semantics, a configured route map with no entry for a model fails loud
  rather than silently falling back.

  ## Resolving

  `model_spec/3` returns the ReqLLM spec for upstream `evaluate/2`, or a
  structured error; `resolver/2` wraps it as the function `evaluate/2`
  accepts. Guards run in order: pin (raises — misconfiguration), region
  (refused), residency policy (refused — the ADR 0026 tenant opt-out,
  enforced next to the client in the action path, never inside a policy
  check, law 3).

  `warm/1` verifies a pinned profile against the runtime's model-listing
  endpoint at boot, so a wrong digest or a cold, absent model is a boot
  failure, never a user request. See `AshJudgments.Profile.Digest`.
  """

  @moduledoc since: "0.1.0"

  defstruct [
    :name,
    :provider,
    :model,
    :base_url,
    :api_key,
    :residency,
    :region,
    :receive_timeout,
    :digest,
    :pin
  ]

  @type residency :: :in_cluster | :sub_processor
  @type region :: :ca | :us
  @type pin :: :required | :optional
  @type system_ref :: {:system, String.t()} | {:system, String.t(), term()}
  # The struct form references cleanly in docs; `ArgumentError.t()` is not
  # in this docset and ex_doc warns on the reference.
  @type invalid_profile :: %ArgumentError{}

  @type t :: %__MODULE__{
          name: atom(),
          provider: atom(),
          model: String.t(),
          base_url: system_ref() | nil,
          api_key: system_ref(),
          residency: residency(),
          region: region(),
          receive_timeout: pos_integer(),
          digest: system_ref() | String.t() | nil,
          pin: pin()
        }

  # Floating ids come in both spellings the runtimes actually use: a
  # dash suffix on the model id ("jev-latest", "m-preview") and a tag
  # after the colon ("nli:latest", "winnow:preview" — the ollaya-style
  # tag form). Both are floating; both are forbidden under a required pin.
  alias AshJudgments.Profile.{
    DigestMismatch,
    DigestUnavailable,
    FloatingAlias,
    MissingEnv,
    MissingPin,
    MissingRegion,
    ProfileNotFound,
    RegionMismatch,
    ResidencyDenied,
    RouteMissing,
    UnsupportedProvider
  }

  @floating_suffixes ["-latest", "-preview", ":latest", ":preview"]

  # The wire contracts this package can resolve inline specs for, keyed by
  # provider. Wire data, not model data: the model id, digest and endpoint
  # all stay in host config; this table only says which request shape a
  # provider's in-zone runtime speaks (req_llm >= 1.26 resolves evaluate
  # calls either from its catalog or from a full inline spec with execution
  # metadata, and an in-zone runtime is in no catalog).
  @wire_contracts %{
    typesafe: %{
      family: "typesafe_systemone",
      wire_protocol: "typesafe_systemone",
      path: "/v1/systemone"
    }
  }
  @default_receive_timeout 30_000

  # The custom validators the schema below dispatches on by symbolic type,
  # keeping the schema pure data (no closures), so `schema/0` is printable
  # and the validators stay private functions.
  defp validate_system_ref(value) do
    case value do
      {:system, var} when is_binary(var) -> :ok
      {:system, var, _default} when is_binary(var) -> :ok
      _ -> {:error, "api_key accepts only {:system, var} references — never a literal (AC-6)"}
    end
  end

  defp validate_digest(value) do
    case value do
      {:system, var} when is_binary(var) ->
        :ok

      digest when is_binary(digest) ->
        if digest == "", do: {:error, "digest cannot be an empty string"}, else: :ok

      _ ->
        {:error, "expected a digest string or {:system, var}, got #{inspect(value)}"}
    end
  end

  @schema [
    name: [type: :atom, required: true, doc: "The profile's name in the registry."],
    provider: [
      type: :atom,
      default: :typesafe,
      doc: "The ReqLLM provider of the wire. The in-zone runtimes speak the `:typesafe` wire."
    ],
    model: [type: :string, required: true, doc: "The model id, exactly as the runtime names it."],
    base_url: [
      type: :system_ref,
      doc:
        "`{:system, var}` for a local runtime (resolved at call time); nil for a hosted spec. Literals are refused."
    ],
    api_key: [
      type: :system_ref,
      required: true,
      doc:
        "`{:system, var}` — never a literal (AC-6). A third element is the fallback when the variable is unset."
    ],
    residency: [
      type: {:in, [:in_cluster, :sub_processor]},
      required: true,
      doc: "The residency class: which zone may run this instrument (law 10)."
    ],
    region: [
      type: {:in, [:ca, :us]},
      required: true,
      doc: "The region this profile is pinned to."
    ],
    receive_timeout: [
      type: :pos_integer,
      default: @default_receive_timeout,
      doc:
        "Per-request timeout in ms. A cold load can exceed 10s; 30s is the default for local profiles."
    ],
    digest: [
      type: :digest,
      doc:
        "The expected model digest (sha256 as the runtime reports it), or `{:system, var}` to read it at call time. Required when pin: :required."
    ],
    pin: [
      type: {:in, [:required, :optional]},
      default: :optional,
      doc: "Whether compliance paths demand the digest pin."
    ]
  ]

  @doc """
  The profile schema, as data: field, type, default, doc. The single source
  for validation and for the docs topic.
  """
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc """
  Builds a validated profile. Returns `{:ok, %Profile{}}` or
  `{:error, ArgumentError}` carrying the offending field.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, invalid_profile()}
  def new(attrs) do
    with {:ok, attrs} <- validate_schema(attrs) do
      {:ok,
       %__MODULE__{
         name: attrs[:name],
         provider: attrs[:provider],
         model: attrs[:model],
         base_url: attrs[:base_url],
         api_key: attrs[:api_key],
         residency: attrs[:residency],
         region: attrs[:region],
         receive_timeout: attrs[:receive_timeout],
         digest: attrs[:digest],
         pin: attrs[:pin]
       }}
    end
  end

  @doc """
  `new/1`, raising. Configuration is host-owned and read at boot; a bad
  profile is a boot failure, not a runtime surprise.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, %ArgumentError{} = error} -> raise error
    end
  end

  @doc """
  The configured registry: `config :ash_judgments, :profiles`, validated
  with `new!/1`. Invalid entries fail loud here, at every read.
  """
  @spec registry() :: [t()]
  def registry do
    :ash_judgments
    |> Application.get_env(:profiles, [])
    |> Enum.map(&new!/1)
  end

  @doc """
  Fetches a configured profile by name.
  """
  @spec fetch(atom() | String.t()) ::
          {:ok, t()} | {:error, ProfileNotFound.t()}
  def fetch(name) when is_atom(name) or is_binary(name) do
    registry()
    |> Enum.find(&(&1.name == name))
    |> case do
      %__MODULE__{} = profile -> {:ok, profile}
      nil -> {:error, ProfileNotFound.exception(name: name)}
    end
  end

  @doc """
  Resolves the ReqLLM model spec for a profile or a question-shaped map,
  suitable as the `evaluate/2` model argument (upstream resolves a plain
  value per call).

  Guards, in order:

  1. **Pin** — `pin: :required` with a floating alias id (a `-latest`/
   `-preview` suffix or a `:latest`/`:preview` tag) raises `FloatingAlias`
   (AC-1); with no digest raises `MissingPin`.
  2. **Region** — a profile whose region differs from the stack's
     configured region returns `{:error, %RegionMismatch{}}`; an
     unconfigured stack region returns `{:error, %MissingRegion{}}`.
  3. **Residency** — the configured `ResidencyPolicy` decides; a refusal
     returns `{:error, %ResidencyDenied{}}` and no call is made (AC-2).

  A question is a map with `:profile` (a `%Profile{}` or a registry name)
  and `:family` (the calibration grouping the policy and pinning read).
  `input` and `context` mirror upstream's resolver shape
  (`fn input, context -> spec end`); the tenant comes from
  `context[:tenant]`.
  """
  @spec model_spec(t() | map(), map(), map()) ::
          {:ok, {atom(), String.t(), keyword()}}
          | {:error,
             RegionMismatch.t()
             | MissingRegion.t()
             | ResidencyDenied.t()
             | ProfileNotFound.t()
             | MissingEnv.t()}
  def model_spec(profile_or_question, input \\ %{}, context \\ %{})

  def model_spec(%__MODULE__{} = profile, _input, context) do
    resolve(profile, context[:family], context)
  end

  def model_spec(%{profile: ref} = question, input, context) when is_map(question) do
    family = Map.get(question, :family) || context[:family]

    with {:ok, profile} <- resolve_ref(ref, input, context) do
      resolve(profile, family, context)
    end
  end

  @doc """
  The function form upstream `evaluate/2` accepts: an arity-2 function of
  `(input, context)` returning the spec, raising on a refused resolution.
  Build it once, pass it as the `model:` argument. Local profiles pair it
  with `req_llm_opts/2` as the action's `req_llm_opts` (the transport
  cannot ride an inline spec).
  """
  @spec resolver(t() | map(), (map() -> map())) ::
          (map(), map() -> %{provider: atom(), id: String.t()} | String.t())
  def resolver(profile_or_question, transform \\ fn spec -> spec end) do
    fn input, context ->
      case model_spec(profile_or_question, input, context) do
        {:ok, spec} -> transform.(spec)
        {:error, exception} -> raise exception
      end
    end
  end

  @doc """
  The ReqLLM call options for a profile: `base_url`, `api_key` and
  `receive_timeout` as upstream's evaluate accepts them under
  `req_llm_opts`. Pass together with `model_spec/3` or `resolver/1`:

      run {AshAi.Actions.Evaluate,
           model: AshJudgments.Profile.resolver(:laya_local),
           req_llm_opts: AshJudgments.Profile.req_llm_opts(:laya_local)}

  Hosts whose profiles resolve `{:system, var}` at runtime compute this
  where the transport is known — the same place the model function runs.
  """
  @spec req_llm_opts(t() | atom() | String.t()) ::
          {:ok, keyword()}
          | {:error, ProfileNotFound.t() | MissingEnv.t()}
  def req_llm_opts(profile_or_name)

  def req_llm_opts(%__MODULE__{} = profile) do
    with {:ok, base_url} <- base_url(profile) do
      opts =
        [
          receive_timeout: profile.receive_timeout,
          api_key: resolve_ref!(profile.api_key, profile)
        ]
        |> maybe_put_base_url(base_url)

      {:ok, opts}
    end
  end

  def req_llm_opts(name) when is_atom(name) or is_binary(name) do
    with {:ok, profile} <- fetch(name) do
      req_llm_opts(profile)
    end
  end

  @doc """
  Verifies a pinned profile against the runtime at boot: pin, region and
  the reported digest (`AshJudgments.Profile.Digest.fetch/1`). Returns
  `:ok` or `{:error, exception}` — a host `Application.start` task calls
  this (or `warm!/1`) so a wrong pin or an absent model is a boot failure,
  never a user request. Unpinned profiles are only reached for (a
  connection-level check); residency needs a tenant and is a call-time
  concern.

  Raises `FloatingAlias` or `MissingPin` for a misconfigured pin (the same
  misconfiguration `model_spec/3` raises).
  """
  @spec warm(t() | atom() | String.t()) ::
          :ok
          | {:error,
             RegionMismatch.t()
             | MissingRegion.t()
             | ProfileNotFound.t()
             | DigestUnavailable.t()
             | DigestMismatch.t()}
  def warm(%__MODULE__{} = profile) do
    with {:ok, _} <- pin_and_region(profile),
         {:ok, reported} <- AshJudgments.Profile.Digest.fetch(profile) do
      AshJudgments.Profile.Digest.verify(profile, reported)
    end
  end

  def warm(name) when is_atom(name) or is_binary(name) do
    with {:ok, profile} <- fetch(name) do
      warm(profile)
    end
  end

  @doc """
  `warm/1`, raising — the form a boot task wants: fail the boot, not the
  first request.
  """
  @spec warm!(t() | atom() | String.t()) :: :ok
  def warm!(profile_or_name) do
    case warm(profile_or_name) do
      :ok -> :ok
      {:error, exception} -> raise exception
    end
  end

  ## Guards and spec building

  defp resolve(profile, family, context) do
    with :ok <- check_pin!(profile),
         {:ok, _} <- pin_and_region(profile),
         :ok <- check_residency(profile, family, context) do
      build_spec(profile)
    end
  end

  defp pin_and_region(profile) do
    # The pin guard raises (misconfiguration); the region guard refuses
    # (data). Both run on every resolution.
    :ok = check_pin!(profile)
    check_region(profile)
  end

  defp check_pin!(%__MODULE__{pin: :required} = profile) do
    cond do
      floating_alias?(profile.model) ->
        raise FloatingAlias, model: profile.model

      missing_digest?(profile) ->
        raise MissingPin, profile_name: profile.name

      true ->
        :ok
    end
  end

  defp check_pin!(%__MODULE__{pin: :optional}), do: :ok

  defp floating_alias?(model) do
    Enum.any?(@floating_suffixes, &String.ends_with?(model, &1))
  end

  defp missing_digest?(%__MODULE__{digest: nil}), do: true
  defp missing_digest?(%__MODULE__{digest: {:system, _var}}), do: false
  defp missing_digest?(%__MODULE__{digest: digest}) when is_binary(digest), do: digest == ""

  defp check_region(profile) do
    case Application.get_env(:ash_judgments, :region) do
      nil ->
        {:error, MissingRegion.exception([])}

      stack_region when stack_region == profile.region ->
        {:ok, stack_region}

      stack_region ->
        # The disclosure event: the attempt's mismatch recorded, the
        # endpoint never named (ADR 0042 — leaving the zone is a
        # disclosure).
        AshJudgments.Telemetry.residency_denied(%{
          profile: profile.name,
          residency: profile.residency,
          profile_region: profile.region,
          stack_region: stack_region,
          region: stack_region,
          refusal: :region_mismatch
        })

        {:error,
         RegionMismatch.exception(
           profile_name: profile.name,
           profile_region: profile.region,
           stack_region: stack_region
         )}
    end
  end

  defp check_residency(profile, family, context) do
    policy =
      Application.get_env(:ash_judgments, :residency_policy, AshJudgments.ResidencyPolicy.Default)

    tenant = context[:tenant]

    if policy.allow?(tenant, profile.residency, family) do
      :ok
    else
      # The disclosure event: the policy refusal's who/what — the
      # tenant, the family, the residency class — never the endpoint.
      AshJudgments.Telemetry.residency_denied(%{
        profile: profile.name,
        residency: profile.residency,
        family: family,
        tenant: tenant,
        region: Application.get_env(:ash_judgments, :region),
        refusal: :policy_denied
      })

      {:error,
       ResidencyDenied.exception(
         profile_name: profile.name,
         residency: profile.residency,
         family: family,
         tenant: tenant,
         policy: policy
       )}
    end
  end

  defp build_spec(%__MODULE__{base_url: nil} = profile) do
    # Catalog profiles resolve by plain string spec; the provider reads its
    # key from the environment and `req_llm_opts/2` contributes the timeout.
    {:ok, "#{profile.provider}:#{profile.model}"}
  end

  defp build_spec(%__MODULE__{} = profile) do
    # Local profiles are in no catalog: a full inline model spec with the
    # provider's execution metadata (the req_llm >= 1.26 evaluate contract).
    # The transport (base_url/api_key/receive_timeout) cannot ride the spec —
    # it flows through `req_llm_opts/2` as call opts. The transport still
    # resolves HERE, though: a configured route map with no entry for this
    # model, or an unset route variable, is a loud resolution failure, never
    # a silent fallback (the clinic-demo spike's semantics).
    with {:ok, wire} <- wire_contract(profile.provider),
         {:ok, _base_url} <- base_url(profile) do
      {:ok,
       %{
         provider: profile.provider,
         id: profile.model,
         model: profile.model,
         provider_model_id: profile.model,
         capabilities: %{evaluate: true},
         execution: %{
           evaluate:
             Map.merge(
               %{
                 supported: true,
                 provider_model_id: profile.model
               },
               wire
             )
         }
       }}
    end
  end

  defp wire_contract(provider) when is_atom(provider) do
    case Map.fetch(@wire_contracts, provider) do
      {:ok, wire} -> {:ok, wire}
      :error -> {:error, UnsupportedProvider.exception(provider: provider)}
    end
  end

  defp maybe_put_base_url(opts, nil), do: opts
  defp maybe_put_base_url(opts, base_url), do: Keyword.put(opts, :base_url, base_url)

  # Two-host routing: a configured route map wins, and — spike semantics —
  # a configured map with no entry for this model is a loud failure, never
  # a silent fallback to the profile's own base_url.
  defp base_url(profile) do
    case Application.get_env(:ash_judgments, :model_routes, %{}) do
      routes when routes == %{} or is_nil(routes) ->
        resolve_optional_ref(profile.base_url, profile)

      routes when is_map(routes) ->
        case Map.fetch(routes, profile.model) do
          {:ok, ref} -> {:ok, resolve_ref!(ref, profile)}
          :error -> {:error, RouteMissing.exception(model: profile.model)}
        end
    end
  end

  defp resolve_ref!({:system, var}, profile) do
    case System.get_env(var) do
      nil -> raise MissingEnv, var: var, profile_name: profile.name
      value -> value
    end
  end

  defp resolve_ref!({:system, var, default}, _profile) do
    System.get_env(var) || default
  end

  defp resolve_ref!(literal, _profile) when is_binary(literal), do: literal

  defp resolve_optional_ref(nil, _profile), do: {:ok, nil}
  defp resolve_optional_ref(ref, profile), do: {:ok, resolve_ref!(ref, profile)}

  defp resolve_ref(ref, _input, _context) when is_atom(ref) or is_binary(ref), do: fetch(ref)
  defp resolve_ref(%__MODULE__{} = profile, _input, _context), do: {:ok, profile}

  ## Schema validation (hand-rolled: the schema is small, the error
  ## messages want to name the field, and no new dependency is warranted)

  defp validate_schema(attrs) do
    attrs = normalize_attrs(attrs)

    # The accumulator IS the (possibly default-filled) attribute list: each
    # field reads what previous fields wrote.
    Enum.reduce_while(@schema, attrs, &apply_field/2)
    |> case do
      {:error, _} = error -> error
      attrs -> {:ok, attrs}
    end
  end

  defp apply_field({field, opts}, acc) do
    value = Keyword.get(acc, field)
    required? = Keyword.get(opts, :required, false)
    has_default? = Keyword.has_key?(opts, :default)

    cond do
      is_nil(value) and required? ->
        {:halt, {:error, ArgumentError.exception("profile field #{inspect(field)} is required")}}

      is_nil(value) and has_default? ->
        {:cont, Keyword.put(acc, field, Keyword.fetch!(opts, :default))}

      is_nil(value) ->
        {:cont, acc}

      true ->
        validate_present_field(field, opts, value, acc)
    end
  end

  defp validate_present_field(field, opts, value, acc) do
    case validate_field(field, opts, value) do
      :ok -> {:cont, acc}
      {:error, reason} -> {:halt, {:error, ArgumentError.exception("#{field}: " <> reason)}}
    end
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.map(attrs, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
    end)
  end

  defp validate_field(_field, opts, value) do
    validate_type(Keyword.fetch!(opts, :type), value)
  end

  defp validate_type(:atom, value),
    do: check(is_atom(value), "expected an atom, got #{inspect(value)}")

  defp validate_type(:string, value),
    do: check(is_binary(value), "expected a string, got #{inspect(value)}")

  defp validate_type(:pos_integer, value) do
    check(is_integer(value) and value > 0, "expected a positive integer, got #{inspect(value)}")
  end

  defp validate_type({:in, values}, value) do
    check(value in values, "expected one of #{inspect(values)}, got #{inspect(value)}")
  end

  defp validate_type(:system_ref, value), do: validate_system_ref(value)
  defp validate_type(:digest, value), do: validate_digest(value)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
