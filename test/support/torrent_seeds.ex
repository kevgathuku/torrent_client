defmodule TorrentSeeds do
  @moduledoc """
  Test-only loopback swarm: craft minimal `.torrent` files around random
  data and serve them over real TCP. Shared by session and CLI tests so
  neither duplicates the seed doubles.
  """

  alias PeerMessage.{Bitfield, Interested, Piece, Request, Unchoke}

  @piece_length 16_384
  @seed_id String.duplicate("S", 20)

  def piece_length, do: @piece_length

  # Minimal single-file .torrent around random data.
  def craft(tmp, tag, pieces, announce \\ "http://127.0.0.1:9/announce") do
    data = for _ <- 1..pieces, do: :crypto.strong_rand_bytes(@piece_length)
    hashes = Enum.map(data, &:crypto.hash(:sha, &1))

    raw_info = %{
      "piece length" => @piece_length,
      "name" => "#{tag}.bin",
      "length" => pieces * @piece_length,
      "pieces" => Enum.join(hashes)
    }

    bytes = Bento.encode!(%{"announce" => announce, "info" => raw_info})
    path = Path.join(tmp, "#{tag}.torrent")
    File.write!(path, bytes)
    {path, raw_info, data}
  end

  def info_hash(raw_info), do: raw_info |> Torrent.info_hash() |> Base.decode16!()

  # Full seed: serves every piece on every connection.
  def seed_for(raw_info, data) do
    {listen, port} = listen!()
    spawn(fn -> seed_loop(listen, raw_info, data) end)
    %Peer{ip_tuple: {127, 0, 0, 1}, port: port}
  end

  # Accept-and-hang: the torrent stays downloading without completing.
  def blackhole do
    {listen, port} = listen!()

    spawn(fn ->
      case :gen_tcp.accept(listen, 10_000) do
        {:ok, sock} -> :gen_tcp.recv(sock, 0, 30_000)
        {:error, _} -> :ok
      end
    end)

    %Peer{ip_tuple: {127, 0, 0, 1}, port: port}
  end

  # Poll `Session.status/1` until `id` reaches `want`.
  def await_status(session, id, want, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_status(session, id, want, deadline)
  end

  defp poll_status(session, id, want, deadline) do
    found = Enum.find(TorrentClient.Session.status(session), &(&1.id == id))

    cond do
      found != nil and found.status == want ->
        found

      System.monotonic_time(:millisecond) > deadline ->
        raise "timed out waiting for #{want}: #{inspect(TorrentClient.Session.status(session))}"

      true ->
        Process.sleep(100)
        poll_status(session, id, want, deadline)
    end
  end

  defp listen! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  defp seed_loop(listen, raw_info, data) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, sock} ->
        spawn(fn ->
          {:ok, bytes} = :gen_tcp.recv(sock, 68, 5_000)
          {:ok, %Handshake{info_hash: info_hash}} = Handshake.deserialize(bytes)
          true = info_hash == info_hash(raw_info)
          :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @seed_id) |> Handshake.serialize())
          {:ok, %Interested{}, <<>>} = recv_frame(sock)
          {:ok, %Unchoke{}, <<>>} = recv_frame(sock)
          send_message(sock, %Bitfield{bits: full_bits(length(data))})
          send_message(sock, %Unchoke{})
          serve_all(sock, data)
        end)

        seed_loop(listen, raw_info, data)

      {:error, _} ->
        :ok
    end
  end

  defp recv_frame(sock) do
    with {:ok, <<length::32-big>>} <- :gen_tcp.recv(sock, 4, 5_000),
         {:ok, payload} <- :gen_tcp.recv(sock, length, 5_000) do
      PeerMessage.decode(<<length::32-big, payload::binary>>)
    end
  end

  defp send_message(sock, message) do
    {:ok, bytes} = PeerMessage.encode(message)
    :ok = :gen_tcp.send(sock, bytes)
  end

  defp full_bits(total), do: :binary.copy(<<0>>, div(total + 7, 8)) |> set_all(total)

  defp set_all(bits, total) do
    for i <- 0..(total - 1), reduce: bits do
      acc ->
        {head, tail} = :erlang.split_binary(acc, div(i, 8))
        <<byte, rest::binary>> = tail
        head <> <<Bitwise.bor(byte, Bitwise.bsr(0b10000000, rem(i, 8)))>> <> rest
    end
  end

  defp serve_all(sock, data) do
    case recv_frame(sock) do
      {:ok, %Request{} = request, <<>>} ->
        send_message(sock, %Piece{
          index: request.index,
          begin: request.begin,
          block: binary_part(Enum.at(data, request.index), request.begin, request.length)
        })

        serve_all(sock, data)

      {:error, _} ->
        :ok
    end
  end
end
