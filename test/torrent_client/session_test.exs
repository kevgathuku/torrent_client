defmodule TorrentClient.SessionTest do
  @moduledoc """
  The multi-torrent session against loopback seeds (real TCP, no
  internet): concurrent torrents, pause/resume/stop addressing, restart
  from resume bytes, distrusted resume, and listen-port selection.
  Seeds and torrent crafting live in `TorrentSeeds`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TorrentClient.{Disk, Session}

  import TorrentSeeds,
    only: [craft: 3, craft: 4, seed_for: 2, blackhole: 0, await_status: 3, await_status: 4]

  setup do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    name = :"session_#{:erlang.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir(), "kog10-session-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    opts = [
      name: name,
      supervisor: sup,
      announce_timeout: 200,
      max_peers: 2,
      recv_timeout: 2_000,
      piece_timeout: 10_000,
      watchdog_timeout: 5_000
    ]

    session = start_supervised!(Supervisor.child_spec({Session, opts}, id: name))

    %{sup: sup, session: session, tmp: tmp}
  end

  defp start_session(sup, extra \\ []) do
    name = :"session_#{:erlang.unique_integer([:positive])}"

    opts =
      [
        name: name,
        supervisor: sup,
        announce_timeout: 200,
        max_peers: 2,
        recv_timeout: 2_000,
        piece_timeout: 10_000,
        watchdog_timeout: 5_000
      ] ++ extra

    # Unique child id: the default (the module) collides on the second session.
    start_supervised!(Supervisor.child_spec({Session, opts}, id: name))
  end

  # -- acceptance --------------------------------------------------------------

  test "two torrents run concurrently", %{session: session, tmp: tmp} do
    {path_a, info_a, data_a} = craft(tmp, "a", 1)
    {path_b, info_b, data_b} = craft(tmp, "b", 1)
    peer_a = seed_for(info_a, data_a)
    peer_b = seed_for(info_b, data_b)

    assert {:ok, id_a} =
             Session.add_torrent(
               path_a,
               [base_dir: Path.join(tmp, "a"), peers: [peer_a]],
               session
             )

    assert {:ok, id_b} =
             Session.add_torrent(
               path_b,
               [base_dir: Path.join(tmp, "b"), peers: [peer_b]],
               session
             )

    assert id_a != id_b
    await_status(session, id_a, :complete)
    await_status(session, id_b, :complete)

    plen = TorrentSeeds.piece_length()
    layout = %{:"piece length" => plen, name: "a.bin", length: plen}
    expected = Enum.at(data_a, 0)
    assert {:ok, ^expected} = Disk.read_piece(Path.join(tmp, "a"), layout, 0)
  end

  test "restart resumes without re-verified loss", %{sup: sup, tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "r", 2)
    base = Path.join(tmp, "r")
    peer = seed_for(raw_info, data)

    # Phase 1: a full download publishes every verified piece to .resume.
    s1 = start_session(sup)
    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [peer]], s1)
    await_status(s1, id, :complete)

    assert {:ok, resume} = Disk.read(Disk.resume_path(base))
    assert {:ok, %{verified: [0, 1], total: 2}} = Disk.decode_resume(resume)

    # Phase 2: a fresh session over the same dir completes with zero
    # peers — nothing is re-downloaded, the resume seeds everything.
    s2 = start_session(sup)
    assert {:ok, ^id} = Session.add_torrent(path, [base_dir: base, peers: []], s2)
    assert %{status: :complete} = await_status(s2, id, :complete, 5_000)
  end

  # -- lifecycle -------------------------------------------------------------

  test "pause stops the subtree and resume restarts it", %{session: session, tmp: tmp} do
    {path, _info, _data} = craft(tmp, "p", 1)
    base = Path.join(tmp, "p")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [blackhole()]], session)
    assert %{status: :downloading} = await_status(session, id, :downloading, 5_000)

    assert {:ok, ^id} = Session.pause(id, session)
    assert %{status: :paused} = await_status(session, id, :paused, 5_000)

    assert {:ok, ^id} = Session.resume(id, session)
    assert %{status: :downloading} = await_status(session, id, :downloading, 5_000)

    assert {:error, :already_running} = Session.resume(id, session)

    assert {:ok, ^id} = Session.forget(id, session)
    assert [] = Session.status(session)
  end

  test "addressing falls back from exact id to prefix to path", %{session: session, tmp: tmp} do
    {path, _info, _data} = craft(tmp, "q", 1)
    base = Path.join(tmp, "q")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [blackhole()]], session)
    prefix = String.slice(id, 0, 8)

    assert {:ok, ^id} = Session.pause(prefix, session)
    assert %{status: :paused} = await_status(session, id, :paused, 5_000)

    assert {:ok, ^id} = Session.resume(path, session)
    assert %{status: :downloading} = await_status(session, id, :downloading, 5_000)

    assert {:error, :already_added} =
             Session.add_torrent(path, [base_dir: base, peers: []], session)

    assert {:error, :not_found} = Session.pause("nope", session)
    assert {:error, :not_found} = Session.resume("nope", session)
    assert {:error, :not_found} = Session.forget("nope", session)
  end

  test "resume on a complete torrent is a no-op", %{session: session, tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "c", 1)
    base = Path.join(tmp, "c")

    assert {:ok, id} =
             Session.add_torrent(
               path,
               [base_dir: base, peers: [seed_for(raw_info, data)]],
               session
             )

    await_status(session, id, :complete)
    assert {:ok, ^id} = Session.resume(id, session)
    assert %{status: :complete} = await_status(session, id, :complete, 5_000)
  end

  test "unreachable trackers wait exhausted instead of failing the add", %{
    session: session,
    tmp: tmp
  } do
    # UDP bypasses the test env's HTTP announce stub, so the dead port
    # exercises the real all-trackers-failed path. The announce fallback
    # (`{:error, _} -> []`) stays uncovered on purpose: tiers always yield
    # at least one URL, so announce_all can only fail on [], which this
    # path never passes — the arm is fail-closed insurance, not live logic.
    {path, _info, _data} = craft(tmp, "e", 1, "udp://127.0.0.1:9/announce")
    base = Path.join(tmp, "e")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base], session)
    assert %{status: :exhausted} = await_status(session, id, :exhausted, 5_000)
  end

  test "lifecycle transitions are logged", %{session: session, tmp: tmp} do
    {path, _info, _data} = craft(tmp, "logged", 1)
    base = Path.join(tmp, "logged")

    log =
      capture_log(fn ->
        {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [blackhole()]], session)
        assert {:ok, ^id} = Session.pause(id, session)
      end)

    assert log =~ "added"
    assert log =~ "paused"
  end

  test "garbage and foreign resume bytes are ignored", %{session: session, tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "g", 1)
    base = Path.join(tmp, "g")
    File.mkdir_p!(base)

    File.write!(Disk.resume_path(base), "not a term")
    peer = seed_for(raw_info, data)
    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [peer]], session)
    await_status(session, id, :complete)

    {:ok, foreign} =
      Disk.encode_resume(%{
        info_hash: :crypto.strong_rand_bytes(20),
        verified: [0],
        total: 1,
        piece_length: TorrentSeeds.piece_length()
      })

    {path2, raw_info2, data2} = craft(tmp, "g2", 1)
    base2 = Path.join(tmp, "g2")
    File.mkdir_p!(base2)
    File.write!(Disk.resume_path(base2), foreign)

    assert {:ok, id2} =
             Session.add_torrent(
               path2,
               [base_dir: base2, peers: [seed_for(raw_info2, data2)]],
               session
             )

    await_status(session, id2, :complete)

    # A directory at the resume path fails the read itself: foreign
    # dotfiles must not break the add either.
    {path3, raw_info3, data3} = craft(tmp, "g3", 1)
    base3 = Path.join(tmp, "g3")
    File.mkdir_p!(base3)
    File.mkdir_p!(Disk.resume_path(base3))

    assert {:ok, id3} =
             Session.add_torrent(
               path3,
               [base_dir: base3, peers: [seed_for(raw_info3, data3)]],
               session
             )

    await_status(session, id3, :complete)
  end

  # -- ports -----------------------------------------------------------------

  test "explicit port is honored and an occupied one falls back", %{sup: sup} do
    {:ok, occupied_sock} = :gen_tcp.listen(0, [])
    {:ok, occupied} = :inet.port(occupied_sock)

    taken = start_session(sup, port: occupied)
    assert Session.port(taken) != occupied

    {:ok, free_sock} = :gen_tcp.listen(0, [])
    {:ok, free} = :inet.port(free_sock)
    :gen_tcp.close(free_sock)

    honored = start_session(sup, port: free)
    assert Session.port(honored) == free

    # The default server is the app session itself.
    assert is_integer(Session.port())

    :gen_tcp.close(occupied_sock)
  end

  # -- remove (kog.25) ---------------------------------------------------------

  test "dry-run lists targets without deleting", %{session: session, tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "d", 1)
    base = Path.join(tmp, "d")

    assert {:ok, id} =
             Session.add_torrent(
               path,
               [base_dir: base, peers: [seed_for(raw_info, data)]],
               session
             )

    await_status(session, id, :complete)
    layout_file = Path.join(base, "d.bin")

    assert {:ok, ^id, targets} = Session.remove(id, [dry_run: true], session)
    assert Disk.resume_path(base) in targets
    assert layout_file in targets
    assert File.exists?(layout_file)
    assert [%{status: :complete}] = Session.status(session)
  end

  # Residue: the remove layout-failure arms (handler reply plus entry
  # log) are uncovered on purpose — entries always carry a valid
  # bento.info, so Torrent.layout/1 cannot fail here; the arms are
  # fail-closed insurance against deleting blind if that invariant
  # ever breaks.
  test "remove deletes layout files and resume but keeps strangers", %{session: session, tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "x", 1)
    base = Path.join(tmp, "x")

    assert {:ok, id} =
             Session.add_torrent(
               path,
               [base_dir: base, peers: [seed_for(raw_info, data)]],
               session
             )

    await_status(session, id, :complete)
    stray = Path.join(base, "stray.txt")
    File.write!(stray, "not ours")

    assert {:ok, ^id, _files} = Session.remove(id, [], session)
    assert [] = Session.status(session)
    refute File.exists?(Path.join(base, "x.bin"))
    refute File.exists?(Disk.resume_path(base))
    assert File.exists?(stray)
    assert File.dir?(base)
  end

  test "remove of an unknown torrent fails", %{session: session} do
    assert {:error, :not_found} = Session.remove("nope", [], session)
  end

  test "terminal reports update status; unknown and skipped reports are ignored", %{
    session: session,
    tmp: tmp
  } do
    {path, _info, _data} = craft(tmp, "rep", 1)
    base = Path.join(tmp, "rep")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [blackhole()]], session)
    raw = Base.decode16!(id)

    send(session, {:peer_skipped, {{1, 2, 3, 4}, 5}})
    assert %{status: :downloading} = TorrentSeeds.await_status(session, id, :downloading, 5_000)

    send(session, {:download_stalled, raw})
    assert %{status: :stalled} = TorrentSeeds.await_status(session, id, :stalled, 5_000)

    send(session, {:swarm_exhausted, raw})
    assert %{status: :exhausted} = TorrentSeeds.await_status(session, id, :exhausted, 5_000)

    # Reports for forgotten torrents are dropped, never crash.
    send(session, {:torrent_complete, :crypto.strong_rand_bytes(20)})
    Process.sleep(100)
    assert %{status: :exhausted} = TorrentSeeds.await_status(session, id, :exhausted, 5_000)
  end

  test "adding a missing file fails without touching the table", %{session: session, tmp: tmp} do
    assert {:error, :enoent} =
             Session.add_torrent(
               "/nonexistent.torrent",
               [base_dir: Path.join(tmp, "zz")],
               session
             )

    assert [] = Session.status(session)
  end

  test "a dead supervisor fails the add but spares the session", %{tmp: tmp} do
    name = :"dsup_#{:erlang.unique_integer([:positive])}"

    sup =
      start_supervised!(
        Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: name)
      )

    session = start_session(sup)
    Supervisor.stop(sup)

    {path, _info, _data} = craft(tmp, "dsup", 1)

    assert {:error, _} =
             Session.add_torrent(path, [base_dir: Path.join(tmp, "dsup")], session)

    assert [] = Session.status(session)
  end

  test "pause and resume work on waiting entries", %{session: session, tmp: tmp} do
    {path, _info, _data} = craft(tmp, "w", 1, "udp://127.0.0.1:9/announce")
    base = Path.join(tmp, "w")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base], session)
    assert %{status: :exhausted} = TorrentSeeds.await_status(session, id, :exhausted, 5_000)

    assert {:ok, ^id} = Session.pause(id, session)
    assert %{status: :paused} = TorrentSeeds.await_status(session, id, :paused, 5_000)
  end

  test "resume after the torrent file vanished fails", %{session: session, tmp: tmp} do
    {path, _info, _data} = craft(tmp, "gone", 1)
    base = Path.join(tmp, "gone")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [blackhole()]], session)
    assert {:ok, ^id} = Session.pause(id, session)
    File.rm!(path)

    assert {:error, :enoent} = Session.resume(id, session)
  end

  test "unwritable data fails removal loudly but still forgets", %{session: session, tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "ro", 1)
    base = Path.join(tmp, "ro")

    assert {:ok, id} =
             Session.add_torrent(
               path,
               [base_dir: base, peers: [seed_for(raw_info, data)]],
               session
             )

    TorrentSeeds.await_status(session, id, :complete)
    File.chmod!(base, 0o555)

    try do
      assert {:ok, ^id, _files} = Session.remove(id, [], session)
      assert [] = Session.status(session)
      assert File.exists?(Path.join(base, "ro.bin"))
    after
      File.chmod!(base, 0o755)
    end
  end

  test "a dead supervisor does not trap pause", %{session: session, tmp: tmp} do
    {path, _info, _data} = craft(tmp, "ds", 1)
    base = Path.join(tmp, "ds")

    assert {:ok, id} = Session.add_torrent(path, [base_dir: base, peers: [blackhole()]], session)

    session |> :sys.get_state() |> Map.fetch!(:supervisor) |> Supervisor.stop()

    assert {:ok, ^id} = Session.pause(id, session)
    assert %{status: :paused} = TorrentSeeds.await_status(session, id, :paused, 5_000)
  end

  test "non-binary addressing fails closed", %{session: session} do
    assert {:error, :not_found} = Session.pause(:atom, session)
    assert {:error, :not_found} = Session.forget(123, session)
  end

  test "config file port is honored when free", %{sup: sup, tmp: tmp} do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, free} = :inet.port(sock)
    :gen_tcp.close(sock)

    cfg = Path.join(tmp, "client.conf")
    File.write!(cfg, "# comment\nport=#{free}\n")

    session = start_session(sup, config_path: cfg)
    assert Session.port(session) == free
  end
end
