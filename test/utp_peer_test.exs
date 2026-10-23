defmodule UtpPeerTest do
  @moduledoc """
  A full piece download through `PeerWorker` over uTP: the scripted
  `UtpPeer` speaks the transport while a BT server loop serves the
  handshake, bitfield, and blocks. Proves the transport behind the
  `:network`/`:sock` seam, plus pid-socket termination.
  """
  use ExUnit.Case, async: true

  alias TorrentClient.{Disk, PeerWorker, UtpSocket}

  alias PeerMessage.{Bitfield, Interested, Piece, Request, Unchoke}

  @peer_id String.duplicate("T", 20)
  @fake_id String.duplicate("F", 20)
  @piece_length 32_768

  setup do
    base = Path.join(System.tmp_dir!(), "kog37-utp-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    info = %{:"piece length" => @piece_length, name: "f.bin", length: @piece_length}
    :ok = Disk.init_layout(base, info)
    data = :crypto.strong_rand_bytes(@piece_length)

    %{base: base, info: info, data: data, hash: :crypto.hash(:sha, data)}
  end

  # -- BT server over the peer's byte stream --------------------------------

  defp serve_bt(info_hash, data) do
    bt = spawn_link(fn -> bt_init() end)
    {peer, port} = UtpPeer.start(bt)
    send(bt, {:peer, peer, info_hash, data})
    {peer, port}
  end

  defp bt_init do
    receive do
      {:peer, peer, info_hash, data} -> bt_loop(peer, info_hash, data, <<>>)
    end
  end

  defp bt_loop(peer, info_hash, data, buf) do
    receive do
      {:peer_bytes, chunk} ->
        bt_loop(peer, info_hash, data, serve_frames(peer, info_hash, data, buf <> chunk))
    end
  end

  defp serve_frames(peer, info_hash, data, <<19, _::binary>> = buf) when byte_size(buf) >= 68 do
    <<hs::binary-size(68), rest::binary>> = buf
    {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(hs)
    send(peer, {:send_bytes, Handshake.init(info_hash, @fake_id) |> Handshake.serialize()})
    serve_frames(peer, info_hash, data, rest)
  end

  defp serve_frames(peer, info_hash, data, <<len::32-big, _::binary>> = buf)
       when byte_size(buf) >= 4 + len do
    <<_len::32-big, payload::binary-size(len), rest::binary>> = buf

    case PeerMessage.decode(<<len::32-big, payload::binary>>) do
      {:ok, %Interested{}, <<>>} ->
        :ok

      {:ok, %Unchoke{}, <<>>} ->
        send(peer, {:send_bytes, encode!(%Bitfield{bits: <<0b10000000>>}) <> encode!(%Unchoke{})})

      {:ok, %Request{index: 0, begin: begin, length: length}, <<>>} ->
        send(
          peer,
          {:send_bytes,
           encode!(%Piece{index: 0, begin: begin, block: binary_part(data, begin, length)})}
        )

      {:ok, _other, <<>>} ->
        :ok
    end

    serve_frames(peer, info_hash, data, rest)
  end

  defp serve_frames(_peer, _info_hash, _data, partial), do: partial

  defp encode!(message) do
    {:ok, bytes} = PeerMessage.encode(message)
    bytes
  end

  # -- tests -----------------------------------------------------------------

  test "downloads a piece over uTP with no TCP involved", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {peer, port} = serve_bt(info_hash, ctx.data)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: port},
        info_hash: info_hash,
        peer_id: @peer_id,
        info: ctx.info,
        piece_index: 0,
        piece_hash: ctx.hash,
        base_dir: ctx.base,
        transport: :utp,
        recv_timeout: 2_000
      )

    assert_receive {:EXIT, ^pid, :normal}, 10_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
    send(peer, {:close})
  end

  test "terminate closes a live uTP connection" do
    {peer, port} = UtpPeer.start(self())
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000
    assert :ok = PeerWorker.terminate(:shutdown, %{socket: pid, sock: UtpSocket})
    refute Process.alive?(pid)
    assert_receive {:peer_fin, _seq}, 2_000
    send(peer, {:close})
  end

  test "rejects an unknown transport at start" do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_transport} =
             PeerWorker.start_link(
               peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: 1},
               info_hash: :crypto.strong_rand_bytes(20),
               peer_id: @peer_id,
               info: %{piece_length: 1, name: "x", length: 1},
               piece_index: 0,
               piece_hash: :crypto.hash(:sha, "x"),
               base_dir: System.tmp_dir!(),
               transport: :bogus
             )
  end

  defmodule RaisingSock do
    @moduledoc false
    @behaviour TorrentClient.SocketBehaviour
    def send(_, _), do: :ok
    def recv(_, _, _), do: {:error, :closed}
    def close(_socket), do: raise("boom")
  end

  defmodule ExitingSock do
    @moduledoc false
    @behaviour TorrentClient.SocketBehaviour
    def send(_, _), do: :ok
    def recv(_, _, _), do: {:error, :closed}
    def close(_socket), do: exit(:boom)
  end

  test "terminate survives a raising or exiting sock close" do
    pid = spawn(fn -> :ok end)
    assert :ok = PeerWorker.terminate(:shutdown, %{socket: pid, sock: RaisingSock})
    assert :ok = PeerWorker.terminate(:shutdown, %{socket: pid, sock: ExitingSock})
  end

  test "terminate on a dead uTP socket is a no-op" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert :ok = PeerWorker.terminate(:shutdown, %{socket: pid, sock: UtpSocket})
  end
end
