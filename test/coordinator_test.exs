defmodule CoordinatorTest do
  @moduledoc """
  The per-torrent coordinator against loopback seed doubles (real TCP, no
  internet): full completion, endgame duplication with wire Cancel,
  watchdog give-up/restart, and poison-peer exhaustion.
  """
  use ExUnit.Case, async: true

  import Mox
  setup :set_mox_private
  setup :verify_on_exit!

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

  alias PeerMessage.{Bitfield, Cancel, Have, Interested, Piece, Request, Unchoke}

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
    {head, tail} = :erlang.split_binary(acc, div(i, 8))
    <<byte, rest::binary>> = tail
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

  # A supervisor restarts the killed coordinator under the same registry
  # name: wait for the incarnation that is not the one we killed.
  defp await_restart(info_hash, old, tries \\ 200) do
    case Registry.lookup(TorrentClient.Registry, {info_hash, :coordinator}) do
      [{pid, _}] when pid != old ->
        pid

      _ when tries > 0 ->
        Process.sleep(20)
        await_restart(info_hash, old, tries - 1)

      _ ->
        flunk("coordinator did not restart")
    end
  end

  defp read_resume(base) do
    with {:ok, bytes} <- Disk.read(Disk.resume_path(base)) do
      Disk.decode_resume(bytes)
    end
  end

  test "a poison peer is skipped in seconds with production timeouts", ctx do
    {listen, port} = listen!()

    # Accept loop: every redial gets a handshake and a bitfield, then
    # silence. Each connection hangs its own socket so the worker's
    # first-byte deadline, not a close, ends the attempt.
    spawn(fn -> poison_loop(listen, ctx.info_hash) end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(
      coord_opts(ctx,
        peers: peers,
        recv_timeout: 10_000,
        piece_timeout: 30_000,
        watchdog_timeout: 300_000,
        max_stalls: 100,
        max_peer_failures: 2
      )
    )

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    # Two silent 5s first-byte cycles and the peer is skipped; without
    # the deadline the same two strikes would cost full 30s pieces and
    # blow past the test timeout.
    assert_receive {:peer_skipped, {{127, 0, 0, 1}, ^port}}, 30_000
    assert_receive {:swarm_exhausted, info_hash, _progress}, 30_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
  end

  defp poison_loop(listen, info_hash) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, sock} ->
        spawn(fn ->
          seed_greet(sock, info_hash, full_bits(2))
          send_message(sock, %Unchoke{})
          hang_open(sock)
        end)

        poison_loop(listen, info_hash)

      {:error, _} ->
        :ok
    end
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

    assert {:error, _} =
             TorrentSupervisor.start_link(coord_opts(ctx, peers: [], verified: [0]))

    # The give-up report carries the progress that survived, so the
    # session can record 1/2 verified instead of a bare status.
    assert_receive {:swarm_exhausted, info_hash, %{verified: 1, total: 2}}, 5_000
    assert info_hash == ctx.info_hash
    Process.flag(:trap_exit, false)
  end

  test "resume seed completes without refetching verified pieces", ctx do
    parent = self()
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      serve_all(sock, ctx.data)
      send(parent, :seed_done)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, verified: [0]))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, info_hash}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    assert_receive :seed_done, 5_000

    assert {:ok, Enum.at(ctx.data, 1)} == Disk.read_piece(ctx.base, ctx.info, 1)
    assert {:ok, resume} = Disk.read(Disk.resume_path(ctx.base))

    assert {:ok, %{verified: [0, 1], total: 2, info_hash: saved_hash}} =
             TorrentClient.Disk.decode_resume(resume)

    assert saved_hash == ctx.info_hash
  end

  test "fully seeded resume reports completion without any peer", ctx do
    start_sup_unlinked(coord_opts(ctx, peers: [], verified: [0, 1]))
    assert_receive {:torrent_complete, info_hash}, 5_000
    assert info_hash == ctx.info_hash
  end

  test "crash restart keeps the published verified set", ctx do
    {listen, port} = listen!()

    # Accept once and hang: the connection never serves, so the manual
    # completions below are the only progress either incarnation sees.
    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      :gen_tcp.recv(sock, 0, 30_000)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, recv_timeout: 30_000))

    pid = coord_pid(ctx.info_hash)

    # First incarnation verifies piece 0 and publishes it before dying.
    send(pid, {:piece_complete, self(), 0})
    assert %{download: %{verified: verified}} = :sys.get_state(pid)
    assert MapSet.member?(verified, 0)
    assert {:ok, %{verified: [0]}} = read_resume(ctx.base)

    # The restart is born with the first incarnation's start opts
    # (verified: []), so it must reseed from the published file.
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    restarted = await_restart(ctx.info_hash, pid)
    state = :sys.get_state(restarted)
    assert MapSet.member?(state.download.verified, 0)
    # Published piece 0 is not re-requested: the only worker is piece 1.
    assert [{_, %{index: 1}}] = Map.to_list(state.workers)

    # The next save keeps piece 0 instead of regressing the file.
    send(restarted, {:piece_complete, self(), 1})
    assert_receive {:torrent_complete, _}, 5_000
    assert {:ok, %{verified: [0, 1]}} = read_resume(ctx.base)
  end

  test "refill hook fires before giving up for real", ctx do
    parent = self()
    {refuse_listen, refuse_port} = listen!()
    {seed_listen, seed_port} = listen!()

    spawn(fn -> refuse_loop(refuse_listen, parent, 0) end)

    # Accept loop: pieces race onto separate connections and the peer
    # supervisor may redial, so serve every generation, not just two.
    spawn(fn -> seed_accept_loop(seed_listen, ctx) end)

    poison = [%Peer{ip_tuple: {127, 0, 0, 1}, port: refuse_port}]
    fresh = [%Peer{ip_tuple: {127, 0, 0, 1}, port: seed_port}]

    refill = fn ->
      send(parent, :refilled)
      fresh
    end

    start_sup_unlinked(coord_opts(ctx, peers: poison, max_peer_failures: 1, refill_peers: refill))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive :refilled, 10_000
    assert_receive {:torrent_complete, info_hash}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  test "refill with only known peers still gives up exhausted", ctx do
    parent = self()
    {listen, port} = listen!()

    spawn(fn -> refuse_loop(listen, parent, 0) end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    # The refill offers nothing new (same poison peer): the swarm is
    # still unassignable, so the give-up stands.
    refill = fn -> peers end

    start_sup_unlinked(coord_opts(ctx, peers: peers, max_peer_failures: 1, refill_peers: refill))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:swarm_exhausted, info_hash, _progress}, 10_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  test "a failed resume save logs without breaking completion", ctx do
    stub(TorrentClient.DiskMock, :write, fn _path, _data -> {:error, :boom} end)
    stub(TorrentClient.DiskMock, :read, fn _path -> {:error, :enoent} end)

    {listen, port} = listen!()

    spawn(fn ->
      case :gen_tcp.accept(listen, 10_000) do
        {:ok, sock} -> :gen_tcp.recv(sock, 0, 30_000)
        {:error, _} -> :ok
      end
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(
      coord_opts(ctx, peers: peers, disk: TorrentClient.DiskMock, recv_timeout: 30_000)
    )

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    # No worker can finish against the hanging seed; drive both
    # completions by hand so the save path runs twice and still ends.
    # Real worker pids: the report carries the reporter's identity, and
    # the second piece is only assigned after the first completes.
    send(pid, {:piece_complete, await_worker(pid, 0), 0})
    send(pid, {:piece_complete, await_worker(pid, 1), 1})

    assert_receive {:torrent_complete, info_hash}, 5_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "empty refill still gives up exhausted", ctx do
    parent = self()
    {listen, port} = listen!()

    spawn(fn -> refuse_loop(listen, parent, 0) end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    refill = fn -> [] end

    start_sup_unlinked(coord_opts(ctx, peers: peers, max_peer_failures: 1, refill_peers: refill))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:swarm_exhausted, info_hash, _progress}, 10_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  test "non-positive peer cap fails fast instead of stalling silently", ctx do
    Process.flag(:trap_exit, true)
    assert {:error, _} = TorrentSupervisor.start_link(coord_opts(ctx, peers: [], max_peers: 0))
    assert {:error, _} = TorrentSupervisor.start_link(coord_opts(ctx, peers: [], max_peers: "4"))
    Process.flag(:trap_exit, false)
  end

  test "unknown transport fails fast with its pair unmapped", ctx do
    Process.flag(:trap_exit, true)

    assert {:error, {:shutdown, {:failed_to_start_child, _, {:invalid_transport, :bogus}}}} =
             TorrentSupervisor.start_link(coord_opts(ctx, peers: [], transport: :bogus))

    Process.flag(:trap_exit, false)
  end

  test "utp transport resolves the paired network and sock seams", ctx do
    start_sup_unlinked(
      coord_opts(ctx, peers: [%Peer{ip_tuple: {127, 0, 0, 1}, port: 1}], transport: :utp)
    )

    pid = coord_pid(ctx.info_hash)
    assert :sys.get_state(pid).network == TorrentClient.UtpNetwork
    assert :sys.get_state(pid).sock == TorrentClient.UtpSocket
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
    assert_receive {:download_stalled, info_hash, _progress}, 10_000
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
    assert_receive {:download_stalled, _, _}, 5_000
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

  test "missing is cleared when the peer gains the piece", ctx do
    # p1 lacks piece 0 at first, so it is recorded missing; while p1
    # works on piece 2 it announces piece 0 via Have. Only p1 ever holds
    # piece 0, so without clearing, the swarm would exhaust instead of
    # completing. Later connections see the gained piece in the
    # bitfield itself, like a real peer would advertise it.
    {listen1, port1} = listen!()
    {listen2, port2} = listen!()

    data = for _ <- 1..3, do: :crypto.strong_rand_bytes(16_384)
    hashes = Enum.map(data, &:crypto.hash(:sha, &1))
    info = %{:"piece length" => 16_384, name: "gain.bin", length: 3 * 16_384}
    :ok = Disk.init_layout(ctx.base, info)

    {:ok, has_zero} = Agent.start_link(fn -> false end)
    parent = self()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen1, 5_000)
      # First connection: piece 0 genuinely missing. The worker exits
      # on the bitfield without requesting (nothing to wait for).
      seed_greet(sock, ctx.info_hash, <<0b01100000>>)
      send_message(sock, %Unchoke{})
      send_message(sock, %PeerMessage.KeepAlive{})
      {:error, :closed} = :gen_tcp.recv(sock, 0, 10_000)
      Agent.update(has_zero, fn _ -> true end)
      gain_loop(listen1, ctx, data, has_zero, parent, port1)
    end)

    # Accept loop, not a single accept: watchdog restarts and retries
    # redial peers, and a served-once seed would starve the redial into
    # timeouts, a skip, and a false exhausted. Every connection gets the
    # same no-piece-0 bitfield; only p1 ever gains piece 0 (via Have).
    spawn(fn -> gain_peer_loop(listen2, ctx, data) end)

    peers = [
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port1},
      %Peer{ip_tuple: {127, 0, 0, 1}, port: port2}
    ]

    # Generous recv budget: loaded runners stall handshakes, and a
    # stall must cost a retry here, not one of the three skip strikes.
    start_sup_unlinked(
      coord_opts(ctx, peers: peers, info: info, piece_hashes: hashes, recv_timeout: 10_000)
    )

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, _}, 15_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    assert {:ok, Enum.at(data, 0)} == Disk.read_piece(ctx.base, info, 0)
    assert {:ok, Enum.at(data, 1)} == Disk.read_piece(ctx.base, info, 1)
    assert {:ok, Enum.at(data, 2)} == Disk.read_piece(ctx.base, info, 2)
  end

  # Hold a connection open, swallowing whatever the worker sends: a
  # single recv would return on the first bytes and close the socket
  # when the process exits, failing the worker mid-test.
  defp hang_open(sock) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, _} -> hang_open(sock)
      {:error, _} -> :ok
    end
  end

  defp gain_peer_loop(listen, ctx, data) do
    case :gen_tcp.accept(listen, 15_000) do
      {:ok, sock} ->
        spawn(fn ->
          seed_greet(sock, ctx.info_hash, <<0b01000000>>)
          serve_all(sock, data)
        end)

        gain_peer_loop(listen, ctx, data)

      {:error, _} ->
        :ok
    end
  end

  # Serves every request instantly. The bitfield reflects whether the
  # peer has gained piece 0 yet; mid-download Have announcements
  # exercise the coordinator's missing-cleared path.
  defp gain_loop(listen, ctx, data, has_zero, parent, port) do
    case :gen_tcp.accept(listen, 15_000) do
      {:ok, sock} ->
        send(parent, {:accepted, port})

        spawn(fn ->
          bits = if Agent.get(has_zero, & &1), do: <<0b11100000>>, else: <<0b01100000>>
          seed_greet(sock, ctx.info_hash, bits)
          if Agent.get(has_zero, & &1), do: send_message(sock, %Have{index: 0})
          serve_all(sock, data)
        end)

        gain_loop(listen, ctx, data, has_zero, parent, port)

      {:error, _} ->
        :ok
    end
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
    assert_receive {:swarm_exhausted, info_hash, _progress}, 10_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  defp seed_accept_loop(listen, ctx) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, sock} ->
        spawn(fn ->
          seed_greet(sock, ctx.info_hash, full_bits(2))
          serve_all(sock, ctx.data)
        end)

        seed_accept_loop(listen, ctx)

      {:error, _} ->
        :ok
    end
  end

  # The worker for `index` may not exist yet (single peer assigns one
  # piece at a time); poll the live coordinator state instead of racing it.
  defp wait_gate(_gate, 0), do: flunk("gate never opened")

  defp wait_gate(gate, n) do
    if Agent.get(gate, & &1) == :open do
      :ok
    else
      Process.sleep(20)
      wait_gate(gate, n - 1)
    end
  end

  defp await_worker(pid, index, tries \\ 100) do
    case Enum.find(:sys.get_state(pid).workers, fn
           {_, %{index: ^index}} -> true
           _ -> false
         end) do
      {wpid, _} ->
        wpid

      nil when tries > 0 ->
        Process.sleep(20)
        await_worker(pid, index, tries - 1)

      nil ->
        flunk("no worker for piece #{index}")
    end
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

  # -- webseed fallback (BEP-19) ------------------------------------------------

  defp webseed_opts(ctx, extra) do
    coord_opts(
      ctx,
      Keyword.merge(
        [peers: [], webseed_urls: ["https://x/"], webseed_http: TorrentClient.WebseedHttpMock],
        extra
      )
    )
  end

  test "dead swarm completes through webseed", ctx do
    [data0, data1] = ctx.data

    # One order-independent expectation: the two piece workers race to
    # the mock, so dispatch on the Range instead of relying on call order.
    TorrentClient.WebseedHttpMock
    |> expect(:get, 2, fn "https://x/c.bin", [{"range", range}] ->
      body =
        case range do
          "bytes=0-32767" -> data0
          "bytes=32768-65535" -> data1
        end

      {:ok, %Tesla.Env{status: 206, body: body}}
    end)

    start_sup_unlinked(webseed_opts(ctx, []))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, info_hash}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000

    assert {:ok, data0} == Disk.read_piece(ctx.base, ctx.info, 0)
    assert {:ok, data1} == Disk.read_piece(ctx.base, ctx.info, 1)
  end

  test "webseed only fills pieces no peer holds", ctx do
    parent = self()
    {listen, port} = listen!()
    [data0, data1] = ctx.data

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, <<0b10000000>>)
      serve_all(sock, ctx.data)
      send(parent, :seed_done)
    end)

    # Any webseed fetch outside piece 1 is an unexpected call and fails the test.
    TorrentClient.WebseedHttpMock
    |> expect(:get, 1, fn "https://x/c.bin", [{"range", "bytes=32768-65535"}] ->
      {:ok, %Tesla.Env{status: 206, body: data1}}
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(webseed_opts(ctx, peers: peers))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, info_hash}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    assert_receive :seed_done, 5_000

    assert {:ok, data0} == Disk.read_piece(ctx.base, ctx.info, 0)
    assert {:ok, data1} == Disk.read_piece(ctx.base, ctx.info, 1)
  end

  test "a failing silent peer yields to webseed after one attempt", ctx do
    parent = self()
    {listen, port} = listen!()
    [data0, data1] = ctx.data

    # First dial is refused (the failure that arms demotion); later dials
    # hang instead of failing, so no supervisor restart can race the
    # coordinator's next assignment — exactly one crash ever happens.
    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      send(parent, :refused)
      :gen_tcp.close(sock)

      case :gen_tcp.accept(listen, 5_000) do
        {:ok, hanging} -> :gen_tcp.recv(hanging, 0, 120_000)
        {:error, _} -> :ok
      end
    end)

    # Order-independent: both piece workers race to the mock.
    TorrentClient.WebseedHttpMock
    |> expect(:get, 2, fn "https://x/c.bin", [{"range", range}] ->
      body =
        case range do
          "bytes=0-32767" -> data0
          "bytes=32768-65535" -> data1
        end

      {:ok, %Tesla.Env{status: 206, body: body}}
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    # One slot serializes every assignment, so no endgame duplicate or
    # busy-window race can fetch around the decision under test: without
    # demotion the piece keeps going back to the hanging peer and the
    # download never completes.
    start_sup_unlinked(webseed_opts(ctx, peers: peers, max_peer_failures: 100, max_peers: 1))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, info_hash}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000

    # The peer got its optimistic dial; the webseed did the rest.
    assert_received :refused

    assert {:ok, data0} == Disk.read_piece(ctx.base, ctx.info, 0)
    assert {:ok, data1} == Disk.read_piece(ctx.base, ctx.info, 1)
  end

  test "every verified piece emits, including the final one", ctx do
    attach_telemetry(self(), ctx.info_hash)
    [data0, data1] = ctx.data

    TorrentClient.WebseedHttpMock
    |> expect(:get, 2, fn "https://x/c.bin", [{"range", range}] ->
      body =
        case range do
          "bytes=0-32767" -> data0
          "bytes=32768-65535" -> data1
        end

      {:ok, %Tesla.Env{status: 206, body: body}}
    end)

    start_sup_unlinked(webseed_opts(ctx, []))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:torrent_complete, _}, 15_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000

    # The final piece's DOWN never reaches the coordinator (it stops in
    # finish/2), so emission must happen on the completion report.
    assert_received {:telemetry, [:torrent_client, :webseed, :fetch_complete], _, %{index: 0}}
    assert_received {:telemetry, [:torrent_client, :webseed, :fetch_complete], _, %{index: 1}}
    Process.sleep(200)
    refute_received {:telemetry, [:torrent_client, :webseed, :fetch_complete], _, _}
  end

  test "orphan completion credits bytes but emits nothing", ctx do
    attach_telemetry(self(), ctx.info_hash)
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      hang_open(sock)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, max_peer_failures: 100))
    pid = coord_pid(ctx.info_hash)

    # Unknown reporter: no assignment to attribute, so no event — but the
    # bytes still count toward the download.
    send(pid, {:piece_complete, self(), 0})

    assert %{download: %{verified: verified}} = :sys.get_state(pid)
    assert MapSet.member?(verified, 0)
    Process.sleep(200)
    refute_received {:telemetry, _, _, _}
  end

  test "dead peer supervisor fails webseed starts and stalls out", ctx do
    # start_child on a dead supervisor exits; the coordinator must stay
    # up and stall out instead of crashing with it.
    dead = spawn(fn -> :ok end)
    dead_ref = Process.monitor(dead)
    assert_receive {:DOWN, ^dead_ref, :process, _, _}

    TorrentClient.WebseedHttpMock
    |> stub(:get, fn _url, _headers -> {:error, :boom} end)

    opts =
      webseed_opts(ctx, [])
      |> Keyword.merge(peer_sup: dead, watchdog_timeout: 50, max_stalls: 1)

    {:ok, pid} = TorrentClient.Coordinator.start_link(opts)
    ref = Process.monitor(pid)

    assert_receive {:download_stalled, info_hash, _progress}, 5_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "failing webseed exhausts instead of spinning", ctx do
    TorrentClient.WebseedHttpMock
    |> stub(:get, fn _url, _headers -> {:error, :econnrefused} end)

    Process.flag(:trap_exit, true)
    start_sup_unlinked(webseed_opts(ctx, max_peer_failures: 2))

    pid = coord_pid(ctx.info_hash)
    ref = Process.monitor(pid)

    assert_receive {:swarm_exhausted, info_hash, _progress}, 15_000
    assert info_hash == ctx.info_hash
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    Process.flag(:trap_exit, false)
  end

  # -- telemetry -----------------------------------------------------------

  # Scoped to one torrent: the handler is global, so without the
  # filter a concurrent (or lingering) coordinator for another torrent
  # would land its events in this test's mailbox.
  defp attach_telemetry(test, info_hash) do
    handler = :"telemetry-test-#{:erlang.unique_integer([:positive])}"

    events = [
      [:torrent_client, :peer, :piece_complete],
      [:torrent_client, :peer, :piece_failed],
      [:torrent_client, :webseed, :fetch_complete],
      [:torrent_client, :webseed, :fetch_failed],
      [:torrent_client, :coordinator, :stall],
      [:torrent_client, :coordinator, :give_up]
    ]

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _ ->
        if metadata[:info_hash] == info_hash do
          send(test, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "peer completion emits duration, bytes, and identity", ctx do
    attach_telemetry(self(), ctx.info_hash)
    {:ok, _} = ManualClock.start_link(1_000_000)
    {listen, port} = listen!()
    test = self()

    # Gate the first response on the test: the worker is assigned (clock
    # frozen) before it can complete, so the duration is exact, not racy.
    gatekeeper =
      spawn(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        send(test, :accepted)
        assert_receive :go, 10_000
        seed_greet(sock, ctx.info_hash, full_bits(2))
        serve_all(sock, ctx.data)
      end)

    spawn(fn -> seed_accept_loop(listen, ctx) end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, clock: ManualClock))

    assert_receive :accepted, 5_000
    ManualClock.advance(1_500)
    send(gatekeeper, :go)
    assert_receive {:torrent_complete, _}, 15_000

    assert_received {:telemetry, [:torrent_client, :peer, :piece_complete],
                     %{duration_ms: duration, bytes: 32_768},
                     %{info_hash: info_hash, peer: {{127, 0, 0, 1}, ^port}}}
                    when duration >= 1500

    assert info_hash == ctx.info_hash
  end

  test "peer failure emits reason and identity", ctx do
    attach_telemetry(self(), ctx.info_hash)
    {listen, port} = listen!()

    spawn(fn ->
      refuse_loop(listen, self(), 0)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]
    start_sup_unlinked(coord_opts(ctx, peers: peers, max_peer_failures: 1))

    assert_receive {:swarm_exhausted, _, _}, 15_000

    assert_received {:telemetry, [:torrent_client, :peer, :piece_failed], %{duration_ms: _},
                     %{peer: {{127, 0, 0, 1}, ^port}, reason: :peer_closed}}
  end

  test "webseed fetch emits result, latency, and bytes", ctx do
    attach_telemetry(self(), ctx.info_hash)
    {:ok, _} = ManualClock.start_link(1_000_000)
    {:ok, gate} = Agent.start_link(fn -> :closed end)
    test = self()
    [data0, data1] = ctx.data

    # Both pieces are assigned synchronously during init, so the first
    # fetch proves the clock advance lands before any completion.
    TorrentClient.WebseedHttpMock
    |> expect(:get, 2, fn "https://x/c.bin", [{"range", range}] ->
      send(test, :fetching)
      wait_gate(gate, 250)

      body =
        case range do
          "bytes=0-32767" -> data0
          "bytes=32768-65535" -> data1
        end

      {:ok, %Tesla.Env{status: 206, body: body}}
    end)

    start_sup_unlinked(webseed_opts(ctx, clock: ManualClock))

    assert_receive :fetching, 5_000
    ManualClock.advance(2_500)
    Agent.update(gate, fn _ -> :open end)
    assert_receive {:torrent_complete, _}, 15_000

    assert_received {:telemetry, [:torrent_client, :webseed, :fetch_complete],
                     %{duration_ms: duration, bytes: 32_768}, %{index: _}}
                    when duration >= 2500
  end

  test "webseed failure emits the fetch reason", ctx do
    attach_telemetry(self(), ctx.info_hash)

    TorrentClient.WebseedHttpMock
    |> stub(:get, fn _url, _headers -> {:error, :econnrefused} end)

    Process.flag(:trap_exit, true)
    start_sup_unlinked(webseed_opts(ctx, max_peer_failures: 1))
    assert_receive {:swarm_exhausted, _, _}, 15_000
    Process.flag(:trap_exit, false)

    assert_received {:telemetry, [:torrent_client, :webseed, :fetch_failed], %{duration_ms: _},
                     %{index: _, reason: {:webseed_error, :webseed_failed}}}
  end

  test "watchdog restart emits a stall event", ctx do
    attach_telemetry(self(), ctx.info_hash)
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      seed_greet(sock, ctx.info_hash, full_bits(2))
      :gen_tcp.recv(sock, 0, 30_000)
    end)

    peers = [%Peer{ip_tuple: {127, 0, 0, 1}, port: port}]

    start_sup_unlinked(
      coord_opts(ctx, peers: peers, watchdog_timeout: 100, max_stalls: 5, piece_timeout: 30_000)
    )

    assert_receive {:telemetry, [:torrent_client, :coordinator, :stall], %{stall_count: count},
                    %{info_hash: info_hash}},
                   10_000

    assert count >= 1
    assert info_hash == ctx.info_hash
  end

  test "give-up emits reason and identity", ctx do
    attach_telemetry(self(), ctx.info_hash)
    Process.flag(:trap_exit, true)
    assert {:error, _} = TorrentSupervisor.start_link(coord_opts(ctx, peers: []))
    Process.flag(:trap_exit, false)

    assert_received {:telemetry, [:torrent_client, :coordinator, :give_up], %{},
                     %{info_hash: info_hash, reason: :swarm_exhausted}}

    assert info_hash == ctx.info_hash
  end
end
