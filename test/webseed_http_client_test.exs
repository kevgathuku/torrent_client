defmodule WebseedHttpStub do
  @moduledoc false
  # Minimal loopback HTTP/1.1 origin for the real webseed client:
  # records requests, answers per the test-installed handler, and always
  # closes the connection so there is no keepalive bookkeeping.

  def start(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, seen} = Agent.start_link(fn -> [] end)
    pid = spawn(fn -> accept_loop(listen, port, handler, seen) end)
    %{port: port, seen: seen, pid: pid, listen: listen}
  end

  def stop(%{pid: pid, listen: listen}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(listen)
  end

  def requests(%{seen: seen}), do: Agent.get(seen, & &1) |> Enum.reverse()

  defp accept_loop(listen, port, handler, seen) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, sock} ->
        spawn(fn -> serve(sock, port, handler, seen) end)
        accept_loop(listen, port, handler, seen)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, port, handler, seen) do
    case read_request(sock, "") do
      {:ok, method, path, headers} ->
        Agent.update(seen, &[{method, path, headers} | &1])
        handler.(sock, port, path, headers)

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(sock)
  end

  defp read_request(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        case :binary.split(acc <> data, "\r\n\r\n") do
          [head, _rest] -> parse_head(head)
          [_] -> read_request(sock, acc <> data)
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_head(head) do
    with [request_line | header_lines] <- String.split(head, "\r\n"),
         [method, path, _version] <- String.split(request_line, " ") do
      {:ok, method, path, Enum.map(header_lines, &parse_header/1)}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp parse_header(line) do
    case String.split(line, ": ", parts: 2) do
      [k, v] -> {String.downcase(k), v}
      [k] -> {String.downcase(k), ""}
    end
  end

  def respond(sock, status, headers, body) do
    :gen_tcp.send(sock, [
      "HTTP/1.1 #{status} x\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end

  # Sends `n` 16 KiB chunks with a delay between them; returns the
  # bytes the client actually accepted before going away.
  def drip(_sock, 0, _test), do: 0

  def drip(sock, n, test) do
    chunk = :crypto.strong_rand_bytes(16_384)
    Process.sleep(50)

    case :gen_tcp.send(sock, chunk) do
      :ok ->
        byte_size(chunk) + drip(sock, n - 1, test)

      {:error, _} ->
        send(test, :client_went_away)
        0
    end
  end
end

defmodule WebseedHttpClientTest do
  use ExUnit.Case, async: false

  alias TorrentClient.WebseedHttpClient

  defp base(stub), do: "http://127.0.0.1:#{stub.port}"

  test "exact 206 succeeds with status and body" do
    data = :crypto.strong_rand_bytes(1024)
    parent = self()

    stub =
      WebseedHttpStub.start(fn sock, _port, _path, headers ->
        send(parent, {:range, header(headers, "range")})
        WebseedHttpStub.respond(sock, 206, [{"content-length", "1024"}], data)
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:ok, %{status: 206, body: ^data}} =
             WebseedHttpClient.get(base(stub) <> "/file", [{"range", "bytes=0-1023"}])

    assert_received {:range, "bytes=0-1023"}
  end

  test "follows a redirect preserving the Range" do
    data = :crypto.strong_rand_bytes(1024)
    parent = self()

    stub =
      WebseedHttpStub.start(fn sock, port, path, headers ->
        case path do
          "/redirect" ->
            WebseedHttpStub.respond(
              sock,
              302,
              [{"location", base(%{port: port}) <> "/file"}, {"content-length", "0"}],
              ""
            )

          "/file" ->
            send(parent, {:file_range, header(headers, "range")})
            WebseedHttpStub.respond(sock, 206, [{"content-length", "1024"}], data)
        end
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:ok, %{status: 206, body: ^data}} =
             WebseedHttpClient.get(base(stub) <> "/redirect", [{"range", "bytes=0-1023"}])

    assert_received {:file_range, "bytes=0-1023"}

    ranges =
      for {_m, _p, headers} <- WebseedHttpStub.requests(stub) do
        header(headers, "range")
      end

    assert ranges == ["bytes=0-1023", "bytes=0-1023"]
  end

  test "aborts an oversized body early without buffering it" do
    test = self()

    stub =
      WebseedHttpStub.start(fn sock, _port, _path, _headers ->
        WebseedHttpStub.respond(sock, 200, [{"content-length", "8388608"}], "")
        sent = WebseedHttpStub.drip(sock, 512, test)
        send(test, {:sent_before_close, sent})
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, :body_too_large} =
             WebseedHttpClient.get(base(stub) <> "/big", [{"range", "bytes=0-1023"}])

    # Draining 8 MiB at 16 KiB per 50 ms would take ~25 s; an early abort
    # returns in a fraction of that.
    assert System.monotonic_time(:millisecond) - t0 < 5_000
    assert_receive {:sent_before_close, sent}, 30_000
    assert sent < 1_048_576
  end

  test "redirect loops fail closed" do
    stub =
      WebseedHttpStub.start(fn sock, port, _path, _headers ->
        WebseedHttpStub.respond(
          sock,
          302,
          [{"location", base(%{port: port}) <> "/loop"}, {"content-length", "0"}],
          ""
        )
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:error, :too_many_redirects} =
             WebseedHttpClient.get(base(stub) <> "/loop", [{"range", "bytes=0-1023"}])

    assert length(WebseedHttpStub.requests(stub)) == 4
  end

  test "callers without a Range get the flat default cap" do
    data = :crypto.strong_rand_bytes(100)

    stub =
      WebseedHttpStub.start(fn sock, _port, _path, _headers ->
        WebseedHttpStub.respond(sock, 200, [{"content-length", "100"}], data)
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:ok, %{status: 200, body: ^data}} = WebseedHttpClient.get(base(stub) <> "/f", [])
  end

  test "garbage Ranges fall back to the default cap" do
    data = :crypto.strong_rand_bytes(100)

    stub =
      WebseedHttpStub.start(fn sock, _port, _path, _headers ->
        WebseedHttpStub.respond(sock, 200, [{"content-length", "100"}], data)
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:ok, %{status: 200, body: ^data}} =
             WebseedHttpClient.get(base(stub) <> "/f", [{"range", "bytes=bogus"}])
  end

  test "redirect without a location returns the bare 302" do
    stub =
      WebseedHttpStub.start(fn sock, _port, _path, _headers ->
        WebseedHttpStub.respond(sock, 302, [{"content-length", "0"}], "")
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:ok, %{status: 302, body: ""}} =
             WebseedHttpClient.get(base(stub) <> "/r", [{"range", "bytes=0-9"}])
  end

  test "mid-handshake close fails closed" do
    stub =
      WebseedHttpStub.start(fn sock, _port, _path, _headers ->
        :gen_tcp.close(sock)
      end)

    on_exit(fn -> WebseedHttpStub.stop(stub) end)

    assert {:error, _} = WebseedHttpClient.get(base(stub) <> "/f", [{"range", "bytes=0-9"}])
  end

  # Residue: the 30 s receive-timeout arms, the mid-read hackney error
  # arms, the stop_async rescue, and the non-tuple header guard are
  # fail-closed insurance for a hung or dying server. Driving them needs
  # real 30 s stalls or closes raced against in-flight chunks, so they
  # stay uncovered by unit tests; the drip test above proves the
  # early-abort path that actually bounds memory.

  test "refused connections fail closed" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    assert {:error, _} =
             WebseedHttpClient.get("http://127.0.0.1:#{port}/file", [{"range", "bytes=0-9"}])
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
