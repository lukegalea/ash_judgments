# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Banding.Changes.EnforceContract do
  @moduledoc false
  # The banding create's only change: the pure record hash over the
  # envelope-class fields, plus the frozen band-contract enforcement
  # (Bridge.Dmn.validate_output/1) BEFORE anything is written (law 2:
  # identical inputs, identical outputs — replay-safe by construction).

  use Ash.Resource.Change

  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Registry.Canonical

  @payload_keys MapSet.new([:record_hash])

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &enforce_and_hash/1)
  end

  defp enforce_and_hash(changeset) do
    case Dmn.validate_output(%{
           band: Ash.Changeset.get_attribute(changeset, :band),
           fact_value: Ash.Changeset.get_attribute(changeset, :fact_value)
         }) do
      :ok ->
        record_hash = record_hash(changeset)
        changeset = Ash.Changeset.force_change_attribute(changeset, :record_hash, record_hash)
        changeset

      {:error, message} ->
        Ash.Changeset.add_error(changeset, ArgumentError.exception(message))
    end
  end

  defp record_hash(changeset) do
    changeset.attributes
    |> Enum.reject(fn {k, v} -> MapSet.member?(@payload_keys, k) or is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), canonical_value(v)} end)
    |> Canonical.digest()
  end

  defp canonical_value(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp canonical_value(v), do: v
end
