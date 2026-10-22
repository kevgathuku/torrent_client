defmodule ScriptSock do
  @moduledoc false
  # Pops one canned response per call, so the worker drives a fully
  # deterministic script without touching TCP.
  @behaviour TorrentClient.SocketBehaviour

  def start(script), do: Agent.start_link(fn -> script end)
  @impl true
  def send(sock, _bytes), do: next(sock)
  @impl true
  def recv(sock, _count, _timeout), do: next(sock)
  @impl true
  def close(_sock), do: :ok

  defp next(sock) do
    # Function-valued script items run in the caller when reached: a
    # gate that blocks until the test releases it, so the worker cannot
    # race past the synchronization point.
    Agent.get_and_update(sock, fn [head | tail] -> {head, tail} end)
    |> case do
      response when is_function(response, 0) -> response.()
      response -> response
    end
  end
end

defmodule PeerWorkerTest do
  @moduledoc """
  The supervised peer worker against loopback fake peers (real TCP, no
  internet) plus Mox doubles for the connect/send edges: handshake,
  bitfield, interest, choked-until-unchoked requests, hash verify, and
  disk write, all fail-closed.
  """
  use ExUnit.Case, async: true

  import Mox

  setup :set_mox_private
  setup :verify_on_exit!

  alias TorrentClient.{Disk, PeerWorker}

  alias PeerMessage.{
    Bitfield,
    Cancel,
    Choke,
    Have,
    Interested,
    KeepAlive,
    NotInterested,
    Piece,
    Request,
    Unchoke
  }

  @peer_id String.duplicate("T", 20)
  @fake_id String.duplicate("F", 20)
  @piece_length 32_768

  setup do
    base = Path.join(System.tmp_dir!(), "kog8-worker-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    info = %{:"piece length" => @piece_length, name: "f.bin", length: @piece_length}
    :ok = Disk.init_layout(base, info)
    data = :crypto.strong_rand_bytes(@piece_length)

    %{base: base, info: info, data: data, hash: :crypto.hash(:sha, data)}
  end

  defp worker_opts(ctx, info_hash, port, extra \\ []) do
    Keyword.merge(
      [
        peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: port},
        info_hash: info_hash,
        peer_id: @peer_id,
        info: ctx.info,
        piece_index: 0,
        piece_hash: ctx.hash,
        base_dir: ctx.base,
        recv_timeout: 2_000
      ],
      extra
    )
  end

  defp listen! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  defp recv_frame(sock) do
    {:ok, <<length::32-big>>} = :gen_tcp.recv(sock, 4, 5_000)
    {:ok, payload} = :gen_tcp.recv(sock, length, 5_000)
    PeerMessage.decode(<<length::32-big, payload::binary>>)
  end

  defp send_message(sock, message) do
    {:ok, bytes} = PeerMessage.encode(message)
    :ok = :gen_tcp.send(sock, bytes)
  end

  defp accept_handshake(listen, info_hash) do
    {:ok, sock} = :gen_tcp.accept(listen, 5_000)
    {:ok, bytes} = :gen_tcp.recv(sock, 68, 5_000)
    {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(bytes)
    sock
  end

  defp greet(sock, info_hash) do
    :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @fake_id) |> Handshake.serialize())
    send_message(sock, %Bitfield{bits: <<0b10000000>>})
    {:ok, %Interested{}, <<>>} = recv_frame(sock)
    {:ok, %Unchoke{}, <<>>} = recv_frame(sock)
    sock
  end

  defp serve_piece(sock, data) do
    {:ok, %Request{index: 0, begin: begin, length: length}, <<>>} = recv_frame(sock)
    true = length <= 16_384
    send_message(sock, %Piece{index: 0, begin: begin, block: binary_part(data, begin, length)})
  end

  test "connect failure stops without retrying internally", ctx do
    expect(TorrentClient.NetworkMock, :connect, fn _peer -> {:error, "refused"} end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        worker_opts(ctx, :crypto.strong_rand_bytes(20), 1, network: TorrentClient.NetworkMock)
      )

    assert_receive {:EXIT, ^pid, {:connect_failed, "refused"}}, 1_000
  end

  test "send on a dead socket stops instead of crashing", ctx do
    stub(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, :bogus} end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        worker_opts(ctx, :crypto.strong_rand_bytes(20), 1, network: TorrentClient.NetworkMock)
      )

    assert_receive {:EXIT, ^pid, {:send_failed, _}}, 1_000
  end

  test "rejects an invalid piece assignment at start", ctx do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_piece} =
             PeerWorker.start_link(
               worker_opts(ctx, :crypto.strong_rand_bytes(20), 1, piece_index: 7)
             )
  end

  test "downloads, verifies and writes one piece, then stops normally", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %KeepAlive{})
      send_message(sock, %Choke{})
      send_message(sock, %Interested{})
      send_message(sock, %NotInterested{})
      send_message(sock, %Have{index: 0})
      send_message(sock, %Request{index: 0, begin: 0, length: 16_384})
      send_message(sock, %Cancel{index: 0, begin: 0, length: 16_384})
      send_message(sock, %Unchoke{})
      serve_piece(sock, ctx.data)
      serve_piece(sock, ctx.data)
      {:error, :closed} = :gen_tcp.recv(sock, 4, 5_000)
      send(parent, :seed_done)
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :normal}, 5_000
    assert_receive :seed_done, 5_000
    assert {:ok, ctx.data} == Disk.read_piece(ctx.base, ctx.info, 0)
  end

  test "wrong peer info-hash stops and writes nothing", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _} = :gen_tcp.recv(sock, 68, 5_000)

      :ok =
        :gen_tcp.send(
          sock,
          Handshake.init(:crypto.strong_rand_bytes(20), @fake_id) |> Handshake.serialize()
        )
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :info_hash_mismatch}, 5_000
    assert {:ok, :binary.copy(<<0>>, @piece_length)} == Disk.read_piece(ctx.base, ctx.info, 0)
  end

  test "garbage handshake bytes stop instead of crashing", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _} = :gen_tcp.recv(sock, 68, 5_000)
      :ok = :gen_tcp.send(sock, <<60>> <> :binary.copy(<<0>>, 67))
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :bad_handshake}, 5_000
  end

  test "corrupt block fails verification and writes nothing", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      {:ok, %Request{index: 0, begin: 0, length: length}, <<>>} = recv_frame(sock)
      send_message(sock, %Piece{index: 0, begin: 0, block: :binary.copy(<<7>>, length)})
      serve_piece(sock, ctx.data)
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :piece_mismatch}, 5_000
    assert {:ok, :binary.copy(<<0>>, @piece_length)} == Disk.read_piece(ctx.base, ctx.info, 0)
  end

  test "off-plan piece is a protocol error", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      {:ok, %Request{}, <<>>} = recv_frame(sock)
      send_message(sock, %Piece{index: 5, begin: 0, block: :binary.copy(<<7>>, 16_384)})
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :unexpected_piece}, 5_000
  end

  test "malformed peer message stops", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      {:ok, %Request{}, <<>>} = recv_frame(sock)
      :ok = :gen_tcp.send(sock, <<1::32-big, 99>>)
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :unknown_message_id}, 5_000
  end

  test "out-of-range Have stops", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Have{index: 99})
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :piece_out_of_range}, 5_000
  end

  test "no request goes out while choked; silence ends in timeout", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)

      case :gen_tcp.recv(sock, 4, 1_000) do
        {:error, :closed} -> send(parent, :no_request)
        {:error, :timeout} -> send(parent, :no_request)
        {:ok, _} -> send(parent, :unexpected_request)
      end
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port, recv_timeout: 300))

    assert_receive {:EXIT, ^pid, :peer_timeout}, 5_000
    assert_receive :no_request, 5_000
  end

  test "peer closing mid-download stops", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      :gen_tcp.close(sock)
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :peer_closed}, 5_000
  end

  test "bitfield lacking the piece stops normally without requesting", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, bytes} = :gen_tcp.recv(sock, 68, 5_000)
      {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(bytes)
      :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @fake_id) |> Handshake.serialize())
      send_message(sock, %Bitfield{bits: <<0b00000000>>})
      {:ok, %Interested{}, <<>>} = recv_frame(sock)
      {:ok, %Unchoke{}, <<>>} = recv_frame(sock)
      send_message(sock, %Unchoke{})

      case :gen_tcp.recv(sock, 4, 1_000) do
        {:error, _} -> send(parent, :closed_clean)
        {:ok, _} -> send(parent, :unexpected_request)
      end
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :normal}, 5_000
    assert_receive :closed_clean, 5_000
  end

  test "block request send failure stops with the reason", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    peer_hs = Handshake.init(info_hash, @fake_id) |> Handshake.serialize()

    {:ok, script} =
      ScriptSock.start([
        :ok,
        {:ok, peer_hs},
        :ok,
        :ok,
        {:ok, <<0, 0, 0, 2>>},
        {:ok, <<5, 0b10000000>>},
        {:ok, <<0, 0, 0, 1>>},
        {:ok, <<1>>},
        {:error, :closed}
      ])

    expect(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, script} end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        worker_opts(ctx, info_hash, 1, network: TorrentClient.NetworkMock, sock: ScriptSock)
      )

    assert_receive {:EXIT, ^pid, {:send_failed, :closed}}, 1_000
  end

  test "unexpected socket error stops with the reason", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    peer_hs = Handshake.init(info_hash, @fake_id) |> Handshake.serialize()

    {:ok, script} =
      ScriptSock.start([
        :ok,
        {:ok, peer_hs},
        :ok,
        :ok,
        {:ok, <<0, 0, 0, 2>>},
        {:ok, <<5, 0b10000000>>},
        {:error, :econnreset}
      ])

    expect(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, script} end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        worker_opts(ctx, info_hash, 1, network: TorrentClient.NetworkMock, sock: ScriptSock)
      )

    assert_receive {:EXIT, ^pid, :econnreset}, 1_000
  end

  defp five_block(ctx) do
    # One piece of five blocks (not five one-block pieces).
    info = %{:"piece length" => 81_920, name: "five.bin", length: 81_920}
    :ok = TorrentClient.Disk.init_layout(ctx.base, info)
    data = :crypto.strong_rand_bytes(81_920)
    {info, data, :crypto.hash(:sha, data)}
  end

  defp recv_requests(_sock, 0, acc), do: Enum.reverse(acc)

  defp recv_requests(sock, n, acc) do
    {:ok, %Request{index: 0, begin: begin, length: length}, <<>>} = recv_frame(sock)
    true = length <= 16_384
    recv_requests(sock, n - 1, [{begin, length} | acc])
  end

  test "pipelines up to 5 block requests per peer", ctx do
    {info, data, hash} = five_block(ctx)
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      requests = recv_requests(sock, 5, [])
      assert Enum.map(requests, &elem(&1, 0)) == [0, 16_384, 32_768, 49_152, 65_536]
      # Serve out of order: assembly must not depend on arrival order.
      for {begin, length} <- Enum.reverse(requests) do
        send_message(sock, %Piece{index: 0, begin: begin, block: binary_part(data, begin, length)})
      end

      {:error, :closed} = :gen_tcp.recv(sock, 4, 5_000)
      send(parent, :seed_done)
    end)

    Process.flag(:trap_exit, true)

    opts =
      worker_opts(ctx, info_hash, port,
        info: info,
        piece_hash: hash,
        max_inflight: 5
      )

    {:ok, pid} = PeerWorker.start_link(opts)

    assert_receive {:EXIT, ^pid, :normal}, 5_000
    assert_receive :seed_done, 5_000
    assert {:ok, data} == TorrentClient.Disk.read_piece(ctx.base, info, 0)
  end

  test "strict peer severs oversized requests and the download still completes", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      {:ok, %Request{length: length} = request, <<>>} = recv_frame(sock)

      if length > 16_384 do
        :gen_tcp.close(sock)
        send(parent, :severed)
      else
        %Request{begin: begin} = request

        send_message(sock, %Piece{
          index: 0,
          begin: begin,
          block: binary_part(ctx.data, begin, length)
        })

        send_message(sock, %Piece{
          index: 0,
          begin: 16_384,
          block: binary_part(ctx.data, 16_384, 16_384)
        })
      end
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port))

    assert_receive {:EXIT, ^pid, :normal}, 5_000
    refute_receive :severed, 500
    assert {:ok, ctx.data} == TorrentClient.Disk.read_piece(ctx.base, ctx.info, 0)
  end

  test "dead peer hits the per-piece deadline and its blocks requeue", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      send(parent, :fake_waiting)
      # Silent from here: the worker's requests go unanswered.
      Process.sleep(5_000)
    end)

    Process.flag(:trap_exit, true)

    opts =
      worker_opts(ctx, info_hash, port,
        piece_timeout: 200,
        report_to: parent
      )

    {:ok, pid} = PeerWorker.start_link(opts)
    missing = [{0, 16_384}, {16_384, 16_384}]

    assert_receive {:EXIT, ^pid, {:piece_timeout, 0, ^missing}}, 5_000
    assert_receive {:piece_timeout, 0, ^missing}, 5_000

    assert {:ok, :binary.copy(<<0>>, @piece_length)} ==
             TorrentClient.Disk.read_piece(ctx.base, ctx.info, 0)
  end

  test "deadline give-up without a report target still stops with the missing set", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      Process.sleep(5_000)
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = PeerWorker.start_link(worker_opts(ctx, info_hash, port, piece_timeout: 200))
    missing = [{0, 16_384}, {16_384, 16_384}]

    assert_receive {:EXIT, ^pid, {:piece_timeout, 0, ^missing}}, 5_000
  end

  test "choke drops in-flight blocks and unchoke re-requests them", ctx do
    {info, data, hash} = five_block(ctx)
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      first = recv_requests(sock, 5, [])
      send_message(sock, %Choke{})
      send_message(sock, %Unchoke{})
      second = recv_requests(sock, 5, [])
      assert second == first
      send(parent, {:resent, length(first) + length(second)})

      for {begin, length} <- second do
        send_message(sock, %Piece{index: 0, begin: begin, block: binary_part(data, begin, length)})
      end
    end)

    Process.flag(:trap_exit, true)

    opts =
      worker_opts(ctx, info_hash, port,
        info: info,
        piece_hash: hash,
        max_inflight: 5
      )

    {:ok, pid} = PeerWorker.start_link(opts)

    assert_receive {:EXIT, ^pid, :normal}, 5_000
    assert_receive {:resent, 10}, 5_000
    assert {:ok, data} == TorrentClient.Disk.read_piece(ctx.base, info, 0)
  end

  test "disk failure stops with the reason", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    expect(TorrentClient.DiskMock, :write_piece, fn _base, _info, _index, _data ->
      {:error, :enospc}
    end)

    spawn(fn ->
      sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
      send_message(sock, %Unchoke{})
      serve_piece(sock, ctx.data)
      serve_piece(sock, ctx.data)
    end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(worker_opts(ctx, info_hash, port, disk: TorrentClient.DiskMock))

    assert_receive {:EXIT, ^pid, {:disk_error, :enospc}}, 5_000
  end

  describe "coordinator reporting" do
    test "reports availability, progress, and completion", ctx do
      info = %{:"piece length" => 16_384, name: "one.bin", length: 16_384}
      :ok = Disk.init_layout(ctx.base, info)
      data = :crypto.strong_rand_bytes(16_384)
      hash = :crypto.hash(:sha, data)
      info_hash = :crypto.strong_rand_bytes(20)
      parent = self()
      {listen, port} = listen!()

      spawn(fn ->
        sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
        send_message(sock, %Unchoke{})
        {:ok, %Request{index: 0, begin: 0, length: 16_384}, <<>>} = recv_frame(sock)
        send_message(sock, %Piece{index: 0, begin: 0, block: data})
        {:error, :closed} = :gen_tcp.recv(sock, 4, 5_000)
      end)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        PeerWorker.start_link(
          worker_opts(ctx, info_hash, port, info: info, piece_hash: hash, report_to: parent)
        )

      assert_receive {:availability, ^pid, set}, 5_000
      assert MapSet.member?(set, 0)
      assert_receive {:block_progress, 0}, 5_000
      assert_receive {:piece_complete, ^pid, 0}, 5_000
      assert_receive {:EXIT, ^pid, :normal}, 5_000
      assert {:ok, data} == Disk.read_piece(ctx.base, info, 0)
    end

    test "reports availability learned from Have messages", ctx do
      info = %{:"piece length" => 16_384, name: "have.bin", length: 16_384}
      :ok = Disk.init_layout(ctx.base, info)
      data = :crypto.strong_rand_bytes(16_384)
      hash = :crypto.hash(:sha, data)
      info_hash = :crypto.strong_rand_bytes(20)
      parent = self()
      {listen, port} = listen!()

      spawn(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, bytes} = :gen_tcp.recv(sock, 68, 5_000)
        {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(bytes)
        :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @fake_id) |> Handshake.serialize())
        send_message(sock, %Have{index: 0})
        {:ok, %Interested{}, <<>>} = recv_frame(sock)
        {:ok, %Unchoke{}, <<>>} = recv_frame(sock)
        send_message(sock, %Unchoke{})
        {:ok, %Request{index: 0, begin: 0, length: 16_384}, <<>>} = recv_frame(sock)
        send_message(sock, %Piece{index: 0, begin: 0, block: data})
        {:error, :closed} = :gen_tcp.recv(sock, 4, 5_000)
      end)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        PeerWorker.start_link(
          worker_opts(ctx, info_hash, port, info: info, piece_hash: hash, report_to: parent)
        )

      assert_receive {:availability, ^pid, set}, 5_000
      assert MapSet.member?(set, 0)
      assert_receive {:EXIT, ^pid, :normal}, 5_000
    end

    test "cancel_piece sends Cancel for outstanding requests and stops", ctx do
      info = %{:"piece length" => 32_768, name: "two.bin", length: 32_768}
      :ok = Disk.init_layout(ctx.base, info)
      data = :crypto.strong_rand_bytes(32_768)
      hash = :crypto.hash(:sha, data)
      info_hash = :crypto.strong_rand_bytes(20)
      parent = self()
      {listen, port} = listen!()

      spawn(fn ->
        sock = listen |> accept_handshake(info_hash) |> greet(info_hash)
        send_message(sock, %Unchoke{})
        # Both requests go out before any block comes back, so the
        # cancel below always finds an outstanding request.
        {:ok, %Request{index: 0, begin: 0}, <<>>} = recv_frame(sock)
        {:ok, %Request{index: 0, begin: 16_384}, <<>>} = recv_frame(sock)
        send_message(sock, %Piece{index: 0, begin: 0, block: binary_part(data, 0, 16_384)})
        send(parent, :sent_first)
        # Hold the final block; keepalives keep the worker iterating so
        # the cancel below is picked up while the request is outstanding.
        keepalive = spawn(fn -> keepalive_loop(sock) end)
        {:ok, %Cancel{index: 0}, <<>>} = recv_frame(sock)
        send(parent, :got_cancel)
        Process.exit(keepalive, :kill)
      end)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        PeerWorker.start_link(
          worker_opts(ctx, info_hash, port,
            info: info,
            piece_hash: hash,
            max_inflight: 2,
            report_to: parent
          )
        )

      assert_receive :sent_first, 5_000
      send(pid, {:cancel_piece, 0})
      assert_receive :got_cancel, 5_000
      assert_receive {:EXIT, ^pid, :normal}, 5_000
    end

    test "stale cancel index is ignored and the piece completes", ctx do
      # Gated on the keepalive receive: the cancel is guaranteed to land
      # report: the cancel arrives while the second block is outstanding.
      # A spurious Cancel send would consume a script item and crash the
      # run, so clean completion proves none was sent.
      info_hash = :crypto.strong_rand_bytes(20)
      peer_hs = Handshake.init(info_hash, @fake_id) |> Handshake.serialize()
      parent = self()

      {:ok, b0} =
        PeerMessage.encode(%Piece{index: 0, begin: 0, block: binary_part(ctx.data, 0, 16_384)})

      <<len0::32-big, payload0::binary>> = b0

      gate = fn ->
        send(parent, :at_gate)

        receive do
          :go -> {:ok, <<0, 0, 0, 0>>}
        end
      end

      {:ok, b1} =
        PeerMessage.encode(%Piece{
          index: 0,
          begin: 16_384,
          block: binary_part(ctx.data, 16_384, 16_384)
        })

      <<len1::32-big, payload1::binary>> = b1

      {:ok, script} =
        ScriptSock.start([
          :ok,
          {:ok, peer_hs},
          :ok,
          :ok,
          {:ok, <<0, 0, 0, 2>>},
          {:ok, <<5, 0b10000000>>},
          {:ok, <<0, 0, 0, 1>>},
          {:ok, <<1>>},
          :ok,
          :ok,
          {:ok, <<len0::32-big>>},
          {:ok, payload0},
          gate,
          {:ok, <<len1::32-big>>},
          {:ok, payload1}
        ])

      expect(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, script} end)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        PeerWorker.start_link(
          worker_opts(ctx, info_hash, 1,
            network: TorrentClient.NetworkMock,
            sock: ScriptSock,
            report_to: parent
          )
        )

      assert_receive {:block_progress, 0}, 1_000
      assert_receive :at_gate, 1_000
      send(pid, {:cancel_piece, 99})
      send(pid, :go)
      assert_receive {:EXIT, ^pid, :normal}, 1_000
      assert {:ok, ctx.data} == Disk.read_piece(ctx.base, ctx.info, 0)
    end

    test "failed Cancel send stops with the reason", ctx do
      info_hash = :crypto.strong_rand_bytes(20)
      peer_hs = Handshake.init(info_hash, @fake_id) |> Handshake.serialize()
      parent = self()

      {:ok, b0} =
        PeerMessage.encode(%Piece{index: 0, begin: 0, block: binary_part(ctx.data, 0, 16_384)})

      <<len0::32-big, payload0::binary>> = b0

      gate = fn ->
        send(parent, :at_gate)

        receive do
          :go -> {:ok, <<0, 0, 0, 0>>}
        end
      end

      {:ok, script} =
        ScriptSock.start([
          :ok,
          {:ok, peer_hs},
          :ok,
          :ok,
          {:ok, <<0, 0, 0, 2>>},
          {:ok, <<5, 0b10000000>>},
          {:ok, <<0, 0, 0, 1>>},
          {:ok, <<1>>},
          :ok,
          :ok,
          {:ok, <<len0::32-big>>},
          {:ok, payload0},
          gate,
          {:error, :closed}
        ])

      expect(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, script} end)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        PeerWorker.start_link(
          worker_opts(ctx, info_hash, 1,
            network: TorrentClient.NetworkMock,
            sock: ScriptSock,
            report_to: parent
          )
        )

      assert_receive {:block_progress, 0}, 1_000
      assert_receive :at_gate, 1_000
      send(pid, {:cancel_piece, 0})
      send(pid, :go)
      assert_receive {:EXIT, ^pid, {:send_failed, :closed}}, 1_000
    end
  end

  defp keepalive_loop(sock) do
    {:ok, bytes} = PeerMessage.encode(%KeepAlive{})
    :ok = :gen_tcp.send(sock, bytes)
    Process.sleep(20)
    keepalive_loop(sock)
  end
end
