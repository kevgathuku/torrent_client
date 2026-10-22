defmodule TorrentClient.RequestsClientTest do
  @moduledoc """
  The real tracker HTTP edge: a hanging tracker fails at the inner
  timeout instead of eating the announce window, and a live one still
  answers through the timeout middleware.
  """
  use ExUnit.Case, async: true

  alias TorrentClient.Requests.TeslaClient

  setup do
    previous = Application.get_env(:torrent_client, :requests_timeout)
    # A second, not the 5s default: fast suite, but roomy under parallel load.
    Application.put_env(:torrent_client, :requests_timeout, 1_000)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:torrent_client, :requests_timeout)
      else
        Application.put_env(:torrent_client, :requests_timeout, previous)
      end
    end)

    :ok
  end

  test "a tracker that accepts but never answers fails fast" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      case :gen_tcp.accept(listen, 5_000) do
        {:ok, sock} -> hold_open(sock)
        {:error, _} -> :ok
      end
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, _} = TeslaClient.get("http://127.0.0.1:#{port}/announce")
    # The 300ms test timeout fired, not the minutes-long adapter default.
    assert System.monotonic_time(:millisecond) - started < 10_000
  end

  # Swallow whatever arrives, forever: a single recv would return on
  # the request bytes and close the socket when the process exits.
  defp hold_open(sock) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, _} -> hold_open(sock)
      {:error, _} -> :ok
    end
  end

  test "a live tracker still answers through the middleware" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nee")
      :gen_tcp.close(sock)
    end)

    assert {:ok, %{status: 200}} = TeslaClient.get("http://127.0.0.1:#{port}/announce")
  end
end
