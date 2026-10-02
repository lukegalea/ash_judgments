# SPDX-FileCopyrightText: 2026 ash_judgments contributors <https://github.com/lukegalea/ash_judgments>
#
# SPDX-License-Identifier: MIT

defmodule AshJudgments.Test.DigestServer do
  @moduledoc """
  A local inets httpd serving a fixed model-listing JSON at `/api/ps` and
  `/api/tags` — the shape the digest pinning reads. OTP inets, no new
  dependency. `start/1` binds an ephemeral port and registers its own
  teardown; returns the base URL.
  """

  @doc "Starts the server and returns its base URL."
  def start(body) do
    dir =
      Path.join(System.tmp_dir!(), "ashjd_digest_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "api"))
    json = Jason.encode!(body)

    File.write!(Path.join(dir, "api/ps"), json)
    File.write!(Path.join(dir, "api/tags"), json)

    :inets.start()

    {:ok, pid} =
      :inets.start(:httpd, [
        {:port, 0},
        {:bind_address, {127, 0, 0, 1}},
        {:server_name, ~c"ashjd_digest_test"},
        {:server_root, ~c"/tmp"},
        {:document_root, String.to_charlist(dir)},
        {:mime_types, [{~c"ps", ~c"application/json"}, {~c"tags", ~c"application/json"}]}
      ])

    port = port!(pid)
    base = "http://127.0.0.1:#{port}"

    ExUnit.Callbacks.on_exit(fn ->
      :inets.stop(:httpd, pid)
      File.rm_rf!(dir)
    end)

    base
  end

  # The httpd does not expose its ephemeral port as a return value; the
  # management API reports it from the server process.
  defp port!(pid) do
    case List.keyfind(:httpd.info(pid), :port, 0) do
      {:port, port} when is_integer(port) -> port
      _ -> flunk!("could not determine the digest server port")
    end
  end

  defp flunk!(message), do: raise(ExUnit.AssertionError, message: message)
end
