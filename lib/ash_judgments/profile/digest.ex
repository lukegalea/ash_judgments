# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Profile.Digest do
  @moduledoc """
  Model-digest pinning against the runtime's model-listing endpoint.

  The evaluate wire returns only a model *name* (`AshAi.Actions.Result.model`),
  never a digest — so the digest comes from the runtime itself. Per the
  judgment-record RFC's Q7 answer, the profile reads the digest from the
  runtime's model-listing endpoint and compares it with the profile's pin.
  `warm/2` does this once at boot; the ledger ticket records the digest on
  every row, so a drift that starts after boot surfaces as a `pin_mismatch`
  on the next pinned call.

  Both listing shapes are consulted: `/api/ps` lists *loaded* models, so an
  unloaded model is looked up in `/api/tags` (every known model) before the
  lookup is allowed to fail.

  ## Scope boundary (deliberate)

  This module makes exactly **one kind** of HTTP call in the whole package
  — the runtime's listing endpoint, a reachability-and-identity check. It
  is not model transport: the evaluate wire stays upstream (`ash_ai` +
  `req_llm`), and this package ships no client for it. The call is wrapped
  here alone (one façade, explicit timeout from the profile's
  `receive_timeout`, no retries) so the surface stays auditable.

  Digests are compared as the runtime reports them: the runtime may report
  a short prefix of the full sha256, so a match is prefix-wise (either
  string a prefix of the other, minimum 12 hex characters). Exact matches
  always pass.
  """

  @moduledoc since: "0.1.0"

  alias AshJudgments.Profile.{DigestMismatch, DigestUnavailable}

  @listing_paths ["/api/ps", "/api/tags"]

  @doc """
  Fetches the digest the runtime reports for the profile's model. Returns
  `{:ok, digest}` or `{:error, %DigestUnavailable{}}` naming the endpoint
  and reason.
  """
  @spec fetch(AshJudgments.Profile.t()) ::
          {:ok, String.t()} | {:error, DigestUnavailable.t()}
  def fetch(%AshJudgments.Profile{} = profile) do
    with {:ok, base} <- listing_base(profile) do
      fetch_from_listings(profile, base)
    end
  end

  # Both listing shapes are consulted in order: /api/ps (loaded models)
  # first, /api/tags (every known model) second. `:wrong_shape` (a 404/405)
  # and a 200-without-entry both mean "try the next listing"; transport and
  # HTTP failures stop the search.
  defp fetch_from_listings(profile, base) do
    @listing_paths
    |> Enum.reduce_while(:none, fn path, _acc ->
      handle_listing(read_listing(profile, base <> path), profile)
    end)
    |> case do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, listing_error(profile, "(listing)", reason)}
      :none -> {:error, listing_error(profile, "(listing)", :model_not_loaded)}
    end
  end

  defp handle_listing(read_result, profile) do
    case read_result do
      {:ok, body} ->
        case digest_for(body, profile) do
          {:ok, digest} -> {:halt, {:ok, digest}}
          :not_found -> {:cont, :none}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      # 404/405: this runtime does not speak this listing shape; try the next.
      {:error, :wrong_shape} ->
        {:cont, :none}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp read_listing(profile, url) do
    case Req.get(url, receive_timeout: profile.receive_timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, decode(body)}
      {:ok, %Req.Response{status: status}} when status in [404, 405] -> {:error, :wrong_shape}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, {:transport, exception}}
    end
  end

  @doc """
  Compares the runtime-reported digest with the profile's configured pin.
  `:ok` on a (prefix-wise) match; `{:error, %DigestMismatch{}}` carrying
  both values otherwise — a failure must be able to name them (AC-4).
  """
  @spec verify(AshJudgments.Profile.t(), String.t() | nil) ::
          :ok | {:error, DigestMismatch.t()}
  def verify(%AshJudgments.Profile{digest: {:system, var}} = profile, reported) do
    case System.get_env(var) do
      nil ->
        # A pin that cannot be read cannot be verified: loud, naming both sides.
        {:error,
         DigestMismatch.exception(
           profile_name: profile.name,
           expected: "{:system, #{var}} (unset)",
           reported: reported
         )}

      expected ->
        verify(%{profile | digest: expected}, reported)
    end
  end

  def verify(%AshJudgments.Profile{digest: expected, name: name}, reported)
      when is_binary(expected) and is_binary(reported) do
    if digest_match?(expected, reported) do
      :ok
    else
      {:error,
       DigestMismatch.exception(
         profile_name: name,
         expected: expected,
         reported: reported
       )}
    end
  end

  # A configured pin compared against nothing cannot match.
  def verify(%AshJudgments.Profile{digest: expected, name: name}, reported)
      when is_binary(expected) do
    {:error,
     DigestMismatch.exception(
       profile_name: name,
       expected: expected,
       reported: reported
     )}
  end

  # Nothing pinned: nothing to verify.
  def verify(%AshJudgments.Profile{digest: nil}, _reported), do: :ok

  @doc """
  Whether two digest strings denote the same model under the prefix rule:
  equal, or one a prefix of the other with the shorter at least 12 hex
  characters.
  """
  @spec digest_match?(String.t(), String.t()) :: boolean()
  def digest_match?(expected, reported) do
    expected = normalize(expected)
    reported = normalize(reported)

    cond do
      expected == reported -> true
      prefix?(expected, reported) -> true
      prefix?(reported, expected) -> true
      true -> false
    end
  end

  defp prefix?(shorter, longer) do
    byte_size(shorter) >= 12 and String.starts_with?(longer, shorter)
  end

  defp normalize(digest), do: digest |> String.trim() |> String.downcase()

  defp listing_base(profile) do
    case profile.base_url do
      {:system, var} ->
        case System.get_env(var) do
          nil -> {:error, listing_error(profile, var, :base_url_not_set)}
          base -> {:ok, String.trim_trailing(base, "/")}
        end

      nil ->
        {:error, listing_error(profile, "(no base_url)", :not_a_local_profile)}
    end
  end

  # Tolerant on purpose: runtimes differ in content-type discipline, so a
  # body Req left as a binary is decoded here rather than trusting the
  # declared type.
  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  # The listing body is a JSON array (or {"models": [...]} envelope) of
  # entries carrying a name and a digest. Field names vary by runtime
  # version; read them tolerantly, and match the profile's model id
  # exactly or by its tag (name "laya:typed-decisions" for model
  # "laya:typed-decisions").
  defp digest_for(%{"models" => models}, profile), do: digest_for(models, profile)

  defp digest_for(models, profile) when is_list(models) do
    models
    |> Enum.find(fn
      %{} = entry ->
        name = entry_name(entry)
        name == profile.model or String.ends_with?(name, profile.model)

      _ ->
        false
    end)
    |> case do
      %{} = entry ->
        case entry_digest(entry) do
          nil -> {:error, :entry_without_digest}
          digest -> {:ok, digest}
        end

      nil ->
        :not_found
    end
  end

  defp digest_for(_other, _profile), do: {:error, :unexpected_shape}

  defp entry_name(%{"name" => name}) when is_binary(name), do: name
  defp entry_name(%{"model" => name}) when is_binary(name), do: name
  defp entry_name(_), do: ""

  defp entry_digest(%{"digest" => digest}) when is_binary(digest), do: digest
  defp entry_digest(_), do: nil

  defp listing_error(profile, endpoint, reason) do
    DigestUnavailable.exception(
      profile_name: profile.name,
      endpoint: endpoint,
      reason: unwrap_reason(reason)
    )
  end

  defp unwrap_reason({:transport, exception}), do: exception
  defp unwrap_reason(reason), do: reason
end
