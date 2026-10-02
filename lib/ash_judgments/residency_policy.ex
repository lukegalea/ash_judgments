# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.ResidencyPolicy do
  @moduledoc """
  The tenant residency behaviour (ADR 0026): may this tenant's data be
  answered by an instrument of this residency class, for this question
  family?

      @impl AshJudgments.ResidencyPolicy
      def allow?(tenant, :sub_processor, :coi), do: Tenant.opted_in?(tenant, :sub_processor)
      def allow?(_tenant, :in_cluster, _family), do: true
      def allow?(_tenant, :sub_processor, _family), do: false

  The host implements it and registers it with
  `config :ash_judgments, :residency_policy, MyApp.ResidencyPolicy`. The
  package calls it from `AshJudgments.Profile.model_spec/3` — in the
  **action path, next to the client**, never inside an Ash policy check
  (law 3) — and a refusal is a structured `ResidencyDenied` error with no
  call made.

  Default posture when the host ships no policy (and the posture hosts
  should keep for tenants with no recorded setting): **deny what leaves
  the zone**. `AshJudgments.ResidencyPolicy.Default` allows `:in_cluster`
  and refuses `:sub_processor` for every tenant — unknown tenants never
  opt in by silence.
  """

  @moduledoc since: "0.1.0"

  @doc "Whether `tenant` may be answered by an instrument of `residency` for `family`."
  @callback allow?(
              tenant :: term(),
              residency :: AshJudgments.Profile.residency(),
              family :: atom() | nil
            ) ::
              boolean()

  @optional_callbacks []

  defmodule Default do
    @moduledoc """
    The package's default posture: in-cluster is allowed for everyone;
    a sub-processor is refused for every tenant. Hosts register their own
    policy to widen it deliberately — an opt-out setting read per tenant —
    and to record the vendor and model version of any sub-processor call
    as their ADR 0026 disclosure.
    """

    @moduledoc since: "0.1.0"

    @behaviour AshJudgments.ResidencyPolicy

    @impl AshJudgments.ResidencyPolicy
    def allow?(_tenant, :in_cluster, _family), do: true
    def allow?(_tenant, :sub_processor, _family), do: false
  end
end
