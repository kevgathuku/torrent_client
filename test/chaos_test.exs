defmodule ChaosTest do
  @moduledoc """
  Adversarial doubles for the effect seams: every seam gets at least
  one test driving a slow or hanging double, so the suite can express
  the hang/degrade class Mox's instant answers cannot.
  """
  use ExUnit.Case, async: true

  import Mox
  setup :set_mox_private
  setup :verify_on_exit!

  alias TorrentClient.{Announcer, Disk, PeerWorker, WebseedWorker}

  @piece_length 16_384

  setup do
    base = Path.join(System.tmp_dir!(), "chaos-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    # Deterministic bytes: the only body ChaosSlowHttp ever serves.
    body = :binary.copy(<<0xAB>>, @piece_length)
    info = %{:"piece length" => @piece_length, name: "c.bin", length: @piece_length}
    :ok = Disk.init_layout(base, info)

    %{base: base, info: info, body: body, hash: :crypto.hash(:sha, body)}
  end

  # -- webseed http seam ---------------------------------------------------

  test "a slow origin still completes the piece", ctx do
    opts = [
      webseed_urls: ["https://slow/f.bin"],
      info: ctx.info,
      piece_index: 0,
      piece_hash: ctx.hash,
      base_dir: ctx.base,
      http: ChaosSlowHttp,
      disk: TorrentClient.Disk,
      report_to: self()
    ]

    {:ok, pid} = WebseedWorker.start_link(opts)
    ref = Process.monitor(pid)

    assert_receive {:block_progress, 0}, 5_000
    assert_receive {:piece_complete, ^pid, 0}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert {:ok, ctx.body} == Disk.read_piece(ctx.base, ctx.info, 0)
  end

  test "a hanging origin wedges the worker: no fetch timeout exists", ctx do
    opts = [
      webseed_urls: ["https://hung/f.bin"],
      info: ctx.info,
      piece_index: 0,
      piece_hash: ctx.hash,
      base_dir: ctx.base,
      http: ChaosHangHttp,
      disk: TorrentClient.Disk,
      report_to: self()
    ]

    {:ok, pid} = WebseedWorker.start_link(opts)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    # Characterization, not approval: the worker is stuck with no
    # deadline on the fetch. When a fetch timeout lands, flip this to
    # assert abnormal termination instead of wedging.
    refute_received {:block_progress, _}
    refute_received {:piece_complete, _, _}
    Process.sleep(300)
    assert Process.alive?(pid)
    refute_received {:block_progress, _}
    refute_received {:piece_complete, _, _}

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  test "a failing origin stops the worker abnormally", ctx do
    opts = [
      webseed_urls: ["https://down/f.bin"],
      info: ctx.info,
      piece_index: 0,
      piece_hash: ctx.hash,
      base_dir: ctx.base,
      http: ChaosErrorHttp,
      disk: TorrentClient.Disk,
      report_to: self()
    ]

    {:ok, pid} = WebseedWorker.start_link(opts)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:webseed_error, :webseed_failed}}, 5_000
  end

  # -- tracker requests seam -------------------------------------------------

  test "a hanging tracker query is bounded by the fan-out timeout" do
    assert {:ok, %{peers: [], interval: nil}} =
             Announcer.announce_all(
               ["http://127.0.0.1:9/announce"],
               fn _url -> ChaosRequestsHang.get("http://127.0.0.1:9/announce") end,
               timeout: 200,
               max_concurrency: 1
             )
  end

  # -- socket seam -----------------------------------------------------------

  test "a silent socket trips the handshake timeout instead of wedging", ctx do
    stub(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, :chaos_socket} end)
    Process.flag(:trap_exit, true)

    opts = [
      peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: 1},
      info_hash: :crypto.strong_rand_bytes(20),
      peer_id: String.duplicate("T", 20),
      info: ctx.info,
      piece_index: 0,
      piece_hash: ctx.hash,
      base_dir: ctx.base,
      network: TorrentClient.NetworkMock,
      sock: ChaosSilentSocket,
      recv_timeout: 100,
      piece_timeout: 5_000,
      report_to: self()
    ]

    {:ok, pid} = PeerWorker.start_link(opts)

    assert_receive {:EXIT, ^pid, :peer_timeout}, 5_000
    Process.flag(:trap_exit, false)
  end

  # -- network seam ----------------------------------------------------------

  test "a hanging connect wedges the worker: no dial timeout exists", ctx do
    opts = [
      peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: 1},
      info_hash: :crypto.strong_rand_bytes(20),
      peer_id: String.duplicate("T", 20),
      info: ctx.info,
      piece_index: 0,
      piece_hash: ctx.hash,
      base_dir: ctx.base,
      network: ChaosHangNetwork,
      sock: ChaosSilentSocket,
      recv_timeout: 100,
      piece_timeout: 300,
      report_to: self()
    ]

    {:ok, pid} = PeerWorker.start_link(opts)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    # Characterization, not approval: connect has no deadline, so the
    # worker sits in it. A dial timeout must flip this to termination.
    Process.sleep(300)
    assert Process.alive?(pid)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  test "a refused connect stops with its reason", ctx do
    Process.flag(:trap_exit, true)

    opts = [
      peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: 1},
      info_hash: :crypto.strong_rand_bytes(20),
      peer_id: String.duplicate("T", 20),
      info: ctx.info,
      piece_index: 0,
      piece_hash: :crypto.strong_rand_bytes(20),
      base_dir: Path.join(System.tmp_dir!(), "chaos-unused"),
      network: ChaosErrorNetwork,
      sock: ChaosSilentSocket,
      report_to: self()
    ]

    {:ok, pid} = PeerWorker.start_link(opts)

    assert_receive {:EXIT, ^pid, {:connect_failed, :chaos_refused}}, 5_000
    Process.flag(:trap_exit, false)
  end
end
