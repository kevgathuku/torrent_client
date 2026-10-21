defmodule CoordinatorTest do
  @moduledoc """
  The per-torrent coordinator against loopback seed doubles (real TCP, no
  internet): full completion, endgame duplication with wire Cancel,
  watchdog give-up/restart, and poison-peer exhaustion.
  """
  use ExUnit.Case, async: false

  defmodule ManualClock do
    @moduledoc false
    # Frozen-until-advanced clock: watchdog checks fire in real time
    # while download time stands still, so stall windows are exact.
    @behaviour TorrentClient.ClockBehaviour
    def start_link(t), do: Agent.start_link(fn -> t end, name: __MODULE__)
    def advance(by), do: Agent.update(__MODULE__, &(&1 + by))
    @impl true
    def monotonic_ms, do: Agent.get(__MODULE__, & &1)
  end

  alias TorrentClient.{Disk, TorrentSupervisor}

  alias PeerMessage.{Bitfield, Cancel, Interested, Piece, Request, Unchoke}

  @peer_id String.duplicate("C", 20)
  @seed_id String.duplicate("S", 20)
  @piece_length 32_768

  setup do
    base = Path.join(System.tmp_dir(), "kog9-coord-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    data0 = :crypto.strong_rand_bytes(@piece_length)
    data1 = :crypto.strong_rand_bytes(@piece_length)
    info = %{:"piece length" => @piece_length, name: "c.bin", length: 2 * @piece_length}
    :ok = Disk.init_layout(base, info)

    %{
      base: base,
      info: info,
      data: [data0, data1],
      hashes: [:crypto.hash(:sha, data0), :crypto.hash(:sha, data1)],
      info_hash: :crypto.strong_rand_bytes(20)
    }
  end

  # -- seed double ---------------------------------------------------------

  defp listen! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
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

  defp seed_greet(sock, info_hash, bits) do
    {:ok, bytes} = :gen_tcp.recv(sock, 68, 5_000)
    {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(bytes)
    :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @seed_id) |> Handshake.serialize())
    {:ok, %Interested{}, <<>>} = recv_frame(sock)
    {:ok, %Unchoke{}, <<>>} = recv_frame(sock)
    send_message(sock, %Bitfield{bits: bits})
    send_message(sock, %Unchoke{})
  end

  defp full_bits(total), do: :binary.copy(<<0>>, div(total + 7, 8)) |> set_all(total)

  defp set_all(bits, total) do
    for i <- 0..(total - 1), reduce: bits do
      acc -> set_bit(acc, i)
    end
  end

  defp set_bit(acc, i) do
    pos = div(i, 8)
    <<head::binary-size(pos), byte, rest::binary>> = acc
    head <> <<Bitwise.bor(byte, Bitwise.bsr(0b10000000, rem(i, 8)))>> <> rest
  end

  # Serve every request instantly until the worker goes away.
  defp serve_all(sock, data) do
    case recv_frame(sock) do
      {:ok, %Request{} = request, <<>>} ->
        serve_request(sock, data, request)
        serve_all(sock, data)

      {:ok, %Cancel{}, <<>>} ->
        serve_all(sock, data)

      {:error, _} ->
        :ok
    end
  end

  defp serve_request(sock, data, %Request{index: index, begin: begin, length: length}) do
    send_message(sock, %Piece{
      index: index,
      begin: begin,
      block: binary_part(Enum.at(data, index), begin, length)
    })
  end

  defp start_sup_unlinked(opts) do
    {:ok, sup} = TorrentSupervisor.start_link(opts)
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)
    sup
  end

  defp coord_pid(info_hash) do
    [{pid, _}] = Registry.lookup(TorrentClient.Registry, {info_hash, :coordinator})
    pid
  end

  defp coord_opts(ctx, extra) do
    Keyword.merge(
      [
        info: ctx.info,
        info_hash: ctx.info_hash,
        piece_hashes: ctx.hashes,
        base_dir: ctx.base,
        peer_id: @peer_id,
        report_to: self(),
        recv_timeout: 2_000,
        piece_timeout: 10_000,
        watchdog_timeout: 5_000
      ],
      extra
    )
  end

  # -- completion ----------------------------------------------------------

  test "single-torrent download completes against a local seed", ctx do
    parent = self()
    {listen1, port1} = listen!()
    {listen2, port2} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen1, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      serve_all(sock, ctx.data)
      send(parent, :seed1_done)
    end)

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen2, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      serve_all(sock, ctx.data)
      send(parent, :seed2_done)
    end)

    peers = [
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port1},
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port2}
    ]

    start_sup_unlinked(coord_opts(ctx, peers: peers))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, info_hash}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    assert_receive :seed1_done, 5_000
    assert_receive :seed2_done, 5_000

    assert {:ok, Enum.at(ctx.data, 0)} == Disk.read_piece(ctx.base, ctx.info, 0)
    assert {:ok, Enum.at(ctx.data, 1)} == Disk.read_piece(ctx.base, ctx.info, 1)
  end

  # -- terminal and defensive edges ----------------------------------------

  test "empty peer list stops exhausted immediately", ctx do
    Process.flag(:trap_exit, true)
    assert {:error, _} = TorrentSupervisor.start_link(coord_opts(ctx, peers: []))
    assert_receive {:swarm_exhausted, info_hash}, 5_000
    assert info_hash == ctx.info_hash
    Process.flag(:trap_exit, false)
  end

  test "unknown exits and messages are ignored", ctx do
    {listen, port} = listen!()

    spawn(fn ->
      accept_loop(listen, ctx.info_hash, self())
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, name: :kog9_probe_sup))
    assert is_pid(Process.whereis(:kog9_probe_sup))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)
    send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    send(pid, {:availability, self(), MapSet.new([0])})
    send(pid, :bogus)
    Process.sleep(100)
    assert Process.alive?(pid)
    refute_received {:DOWN, ^ref, :process, ^pid, _}
  end

  test "abnormal stop reaps live workers", ctx do
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      :gen_tcp.recv(sock, 0, 30_000)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    sup = start_sup_unlinked(coord_opts(ctx, peers: peers))
    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    # Wait for the worker to be up, then kill the coordinator abnormally:
    # terminate/2 must reap the orphaned worker.
    Process.sleep(200)
    [worker] = :sys.get_state(pid).workers |> Map.keys()
    wref = Process.monitor(worker)
    GenServer.stop(pid, :boom)
    assert_receive {:DOWN, ^ref, :process, ^pid, :boom}, 5_000
    assert_receive {:DOWN, ^wref, :process, ^worker, _}, 5_000
    if Process.alive?(sup), do: Supervisor.stop(sup)
  end

  test "watchdog restart survives a dead peer supervisor", ctx do
    # Resume notes: two coordinator branches are unreachable in
    # deterministic tests. (1) stop_worker's supervisor-dead catch: killing
    # the supervisor always kills its workers first, so their DOWNs clear
    # the map before any restart can address them; it guards only the
    # restart race (supervisor dying mid-sweep). (2) pick/4's excluded guard:
    # assign/2 now filters zero-count pieces itself, so a retried index can
    # never come back; the guard stays as the loop-termination proof.
    {listen, port} = listen!()

    spawn(fn ->
      accept_loop(listen, ctx.info_hash, self())
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    sup =
      start_sup_unlinked(
        coord_opts(ctx, peers: peers, watchdog_timeout: 500, max_stalls: 5, piece_timeout: 30_000)
      )

    pid = coord_pid(ctx.info_hash)
    [{peer_sup, _}] = Registry.lookup(TorrentClient.Registry, {ctx.info_hash, :peer_sup})
    :ok = Supervisor.terminate_child(sup, TorrentClient.PeerSupervisor)
    :ok = Supervisor.delete_child(sup, TorrentClient.PeerSupervisor)
    refute Process.alive?(peer_sup)
    # The next watchdog restart runs stop_worker against the dead sup;
    # the coordinator must survive it.
    Process.sleep(500)
    assert Process.alive?(pid)
  end

  # -- degraded inputs -------------------------------------------------------

  test "dead peer supervisor fails worker starts without crashing", ctx do
    missing = {:via, Registry, {TorrentClient.Registry, {:kog9_nowhere, make_ref()}}}

    {:ok, pid} =
      TorrentClient.Coordinator.start_link(
        coord_opts(ctx, peers: [%Peer{ip_tuple: {127, 0, 0, 1}, port: 1}], peer_sup: missing)
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    Process.sleep(100)
    assert Process.alive?(pid)
    assert :sys.get_state(pid).workers == %{}
  end

  test "inconsistent hashes fail worker starts without crashing", ctx do
    # Two hashes but room for one piece: piece 0 downloads, piece 1 can
    # never start a worker, and the coordinator survives it.
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      serve_all(sock, ctx.data)
    end)

    info = %{:"piece length" => @piece_length, name: "one.bin", length: @piece_length}
    :ok = Disk.init_layout(ctx.base, info)
    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(coord_opts(ctx, peers: peers, info: info))

    pid = coord_pid(ctx.info_hash)
    Process.sleep(500)
    assert Process.alive?(pid)
    assert :sys.get_state(pid).workers == %{}
    assert {:ok, Enum.at(ctx.data, 0)} == Disk.read_piece(ctx.base, info, 0)
  end

  test "worker give-up requeues the piece for a fresh dial", ctx do
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      accept_loop(listen, ctx.info_hash, parent)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(coord_opts(ctx, peers: peers, piece_timeout: 300, max_peer_failures: 10))

    # The stuck worker gives up and a fresh worker dials the same peer.
    assert_receive :accepted, 5_000
    assert_receive :accepted, 5_000
  end

  test "endgame duplicates send cancel on first completion", ctx do
    parent = self()
    {listen1, port1} = listen!()
    {listen2, port2} = listen!()
    # First connection asking for piece 0 gets the hold treatment; the
    # duplicate (second piece-0 connection) is served instantly.
    {:ok, holds} = Agent.start_link(fn -> 0 end)

    spawn(fn -> accept_loop_endgame(listen1, ctx, holds, parent) end)
    spawn(fn -> accept_loop_endgame(listen2, ctx, holds, parent) end)

    peers = [
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port1},
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port2}
    ]

    start_sup_unlinked(coord_opts(ctx, peers: peers))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    # The held original must see a Cancel for its outstanding request.
    assert_receive {:cancelled, %PeerMessage.Cancel{index: 0}}, 15_000
    assert_receive {:torrent_complete, _}, 15_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000

    assert {:ok, Enum.at(ctx.data, 0)} == Disk.read_piece(ctx.base, ctx.info, 0)
    assert {:ok, Enum.at(ctx.data, 1)} == Disk.read_piece(ctx.base, ctx.info, 1)
  end

  defp accept_loop_endgame(listen, ctx, holds, parent) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        spawn(fn -> handle_endgame_conn(sock, ctx, holds, parent) end)
        accept_loop_endgame(listen, ctx, holds, parent)

      {:error, :timeout} ->
        # No newcomer within the window; the hold may still be active.
        accept_loop_endgame(listen, ctx, holds, parent)

      {:error, _} ->
        :ok
    end
  end

  defp handle_endgame_conn(sock, ctx, holds, parent) do
    seed_greet(sock, ctx.info_hash, full_bits(2))
    # The first request decides the policy; it still needs answering.
    {:ok, %Request{index: index} = first, <<>>} = recv_frame(sock)

    if index == 1 do
      serve_request(sock, ctx.data, first)
      serve_all(sock, ctx.data)
    else
      hold_count = Agent.get_and_update(holds, fn n -> {n, n + 1} end)

      if hold_count == 0 do
        hold_piece0(sock, ctx, parent, first)
      else
        serve_request(sock, ctx.data, first)
        serve_all(sock, ctx.data)
      end
    end
  end

  defp hold_piece0(sock, ctx, parent, %Request{index: 0, begin: 0}) do
    # Answer the detected first block, hold the second, and keep the
    # worker iterating with keepalives. The cancel for the held request
    # arrives after any still-buffered request frames, so drain until it
    # shows up.
    serve_request(sock, ctx.data, %Request{index: 0, begin: 0, length: 16_384})
    keepalive = spawn(fn -> seed_keepalive(sock) end)
    await_cancel(sock, parent)
    Process.exit(keepalive, :kill)
  end

  defp await_cancel(sock, parent) do
    case recv_frame(sock) do
      {:ok, %Cancel{index: 0} = cancel, <<>>} -> send(parent, {:cancelled, cancel})
      {:ok, %Request{}, <<>>} -> await_cancel(sock, parent)
      {:error, _} -> send(parent, :seed_closed)
    end
  end

  defp seed_keepalive(sock) do
    {:ok, bytes} = PeerMessage.encode(%PeerMessage.KeepAlive{})
    :ok = :gen_tcp.send(sock, bytes)
    Process.sleep(20)
    seed_keepalive(sock)
  end

  # -- watchdog ------------------------------------------------------------

  test "stalled download gives up after the stall budget", ctx do
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      # Silent from here: handshake done, no blocks ever. Exits when
      # the worker goes away and closes the socket.
      :gen_tcp.recv(sock, 0, 30_000)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(
      coord_opts(ctx, peers: peers, watchdog_timeout: 100, max_stalls: 0, piece_timeout: 30_000)
    )

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)
    assert_receive {:download_stalled, info_hash}, 10_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    # No worker is left behind to dial against the dead coordinator.
    [{peer_sup, _}] = Registry.lookup(TorrentClient.Registry, {ctx.info_hash, :peer_sup})
    assert DynamicSupervisor.which_children(peer_sup) == []
  end

  test "watchdog sees fresh progress as healthy", ctx do
    # Frozen clock: checks fire in real time but download time never
    # advances past the budget, so every check takes the healthy branch.
    # Advancing then proves the timer is live, not disconnected.
    {:ok, _} = ManualClock.start_link(1_000_000)
    {listen, port} = listen!()

    spawn(fn ->
      accept_loop(listen, ctx.info_hash, self())
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(
      coord_opts(ctx, peers: peers, clock: ManualClock, watchdog_timeout: 50, max_stalls: 0)
    )

    pid = coord_pid(ctx.info_hash)
    Process.sleep(200)
    assert Process.alive?(pid)
    assert :sys.get_state(pid).stall_count == 0
    ManualClock.advance(1_000)
    assert_receive {:download_stalled, _}, 5_000
  end

  test "watchdog restarts stuck workers before giving up", ctx do
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      accept_loop(listen, ctx.info_hash, parent)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(
      coord_opts(ctx,
        peers: peers,
        watchdog_timeout: 500,
        max_stalls: 5,
        piece_timeout: 30_000,
        max_peers: 1
      )
    )

    # One accept per worker generation: the first plus a restart.
    assert_receive :accepted, 10_000
    assert_receive :accepted, 10_000
  end

  defp accept_loop(listen, info_hash, parent) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        send(parent, :accepted)
        seed_greet(sock, info_hash, full_bits(2))
        # One block counts as progress, then silence: the first watchdog
        # check sees no stall, later ones restart the worker.
        serve_first_block(sock)
        :gen_tcp.recv(sock, 0, 30_000)
        accept_loop(listen, info_hash, parent)

      {:error, _} ->
        :ok
    end
  end

  defp serve_first_block(sock) do
    case recv_frame(sock) do
      {:ok, %Request{index: index, begin: begin, length: length}, <<>>} ->
        send_message(sock, %Piece{index: index, begin: begin, block: :binary.copy(<<0>>, length)})

      {:error, _} ->
        :ok
    end
  end

  # -- poison peers --------------------------------------------------------

  test "completed worker is forgotten before the next assignment", ctx do
    # Single peer forces sequential pieces: each completion's DOWN lands
    # while the coordinator is still working, exercising the verified
    # exit path (parallel completions usually outrun their DOWNs).
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      accept_count_loop(listen, ctx, parent, port)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, max_peers: 1))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, _}, 15_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    assert_receive {:accepted, ^port}, 5_000
    assert_receive {:accepted, ^port}, 5_000
    refute_received {:accepted, _}
    assert {:ok, Enum.at(ctx.data, 0)} == Disk.read_piece(ctx.base, ctx.info, 0)
    assert {:ok, Enum.at(ctx.data, 1)} == Disk.read_piece(ctx.base, ctx.info, 1)
  end

  test "peer lacking a piece is recorded missing and the piece reroutes", ctx do
    parent = self()
    {listen1, port1} = listen!()
    {listen2, port2} = listen!()

    # p1 only has piece 1: the worker assigned piece 0 learns that from
    # a KeepAlive-driven loop and exits normally without requesting.
    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen1, 5_000)
      send(parent, {:accepted, port1})
      seed_greet(sock, ctx.info_hash, <<0b01000000>>)
      send_message(sock, %Unchoke{})
      send_message(sock, %PeerMessage.KeepAlive{})
      :gen_tcp.recv(sock, 0, 30_000)
    end)

    spawn(fn ->
      accept_count_loop(listen2, ctx, parent, port2)
    end)

    peers = [
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port1},
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port2}
    ]

    start_sup_unlinked(coord_opts(ctx, peers: peers))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, _}, 15_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    # p1 served one connection (the rerouted piece went to p2 twice).
    assert_receive {:accepted, ^port1}, 5_000
    assert_receive {:accepted, ^port2}, 5_000
    assert_receive {:accepted, ^port2}, 5_000
    refute_received {:accepted, _}
  end

  defp accept_count_loop(listen, ctx, parent, port) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        send(parent, {:accepted, port})

        spawn(fn ->
          seed_greet(sock, ctx.info_hash, full_bits(2))
          serve_all(sock, ctx.data)
        end)

        accept_count_loop(listen, ctx, parent, port)

      {:error, _} ->
        :ok
    end
  end

  test "failing peer is skipped after the failure budget, then exhausted", ctx do
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      refuse_loop(listen, parent, 0)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    peer_key = {{127, 0, 0, 1}, port}

    start_sup_unlinked(coord_opts(ctx, peers: peers, max_peer_failures: 1))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)
    # At least the coordinator's own dial; supervisor-restart orphans may
    # add more, so this is a lower bound, not an exact count.
    assert_receive :refused, 5_000
    assert_receive {:peer_skipped, ^peer_key}, 10_000
    assert_receive {:swarm_exhausted, info_hash}, 10_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  defp refuse_loop(listen, parent, _n) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        send(parent, :refused)
        refuse_loop(listen, parent, 0)

      {:error, _} ->
        :ok
    end
  end
end
