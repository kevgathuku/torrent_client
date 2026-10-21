defmodule Mix.Tasks.TorrentTest do
  @moduledoc """
  The `mix torrent` verbs against the app session with `TorrentSeeds`
  loopbacks. Prompt answers feed through `capture_io` stdin.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import TorrentSeeds, only: [craft: 3, craft: 4, seed_for: 2, blackhole: 0, await_status: 3]

  alias TorrentClient.Session

  @task Mix.Tasks.Torrent

  setup do
    tmp = Path.join(System.tmp_dir(), "kog10-cli-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp add_seeded(path, base, raw_info, data) do
    {:ok, id} = Session.add_torrent(path, base_dir: base, peers: [seed_for(raw_info, data)])
    on_exit(fn -> Session.forget(id) end)
    await_status(Session, id, :complete)
    id
  end

  test "parse prints hash, pieces, and total", %{tmp: tmp} do
    {path, _info, _data} = craft(tmp, "parse", 2)

    output = capture_io(fn -> @task.run(["parse", path]) end)
    assert output =~ "info_hash: "
    assert output =~ "pieces: 2"
    assert output =~ "total: #{2 * TorrentSeeds.piece_length()} bytes"
  end

  test "parse of a missing file raises" do
    assert_raise Mix.Error, ~r/cannot parse/, fn ->
      @task.run(["parse", "/nonexistent.torrent"])
    end

    assert_raise Mix.Error, ~r/usage/, fn -> @task.run(["parse"]) end
  end

  test "download of a missing file raises" do
    assert_raise Mix.Error, ~r/cannot add/, fn ->
      @task.run(["download", "/nonexistent.torrent"])
    end

    assert_raise Mix.Error, ~r/usage/, fn -> @task.run(["download"]) end
  end

  test "download completes from existing resume without refetching", %{tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "dl", 1)
    base = Path.join(tmp, "dl")
    id = add_seeded(path, base, raw_info, data)
    assert {:ok, _} = Session.forget(id)

    output = capture_io(fn -> @task.run(["download", path, "--dir", base]) end)
    assert output =~ "complete #{id}"
    assert {:ok, _} = Session.forget(id)
  end

  test "download raises when the swarm exhausts", %{tmp: tmp} do
    {path, _info, _data} = craft(tmp, "dlx", 1, "udp://127.0.0.1:9/announce")
    base = Path.join(tmp, "dlx")

    assert_raise Mix.Error, ~r/exhausted/, fn ->
      @task.run(["download", path, "--dir", base, "--timeout", "50"])
    end
  end

  test "status lists entries and filters by id", %{tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "st", 1)
    base = Path.join(tmp, "st")
    id = add_seeded(path, base, raw_info, data)

    output = capture_io(fn -> @task.run(["status"]) end)
    assert output =~ id
    assert output =~ "complete"

    filtered = capture_io(fn -> @task.run(["status", id]) end)
    assert filtered =~ id

    assert {:ok, _} = Session.forget(id)
  end

  test "pause, resume, and forget wire through addressing", %{tmp: tmp} do
    {path, _info, _data} = craft(tmp, "pr", 1)
    base = Path.join(tmp, "pr")
    {:ok, id} = Session.add_torrent(path, base_dir: base, peers: [blackhole()])
    on_exit(fn -> Session.forget(id) end)

    assert capture_io(fn -> @task.run(["pause", id]) end) =~ "pause #{id}"
    assert capture_io(fn -> @task.run(["resume", path]) end) =~ "resume #{id}"
    assert capture_io(fn -> @task.run(["forget", String.slice(id, 0, 8)]) end) =~ "forget #{id}"

    assert_raise Mix.Error, ~r/not_found/, fn -> @task.run(["pause", "nope"]) end
    assert_raise Mix.Error, ~r/usage/, fn -> @task.run(["forget"]) end
    assert_raise Mix.Error, ~r/unknown torrent command/, fn -> @task.run(["frobnicate"]) end
    assert_raise Mix.Error, ~r/usage/, fn -> @task.run([]) end
  end

  test "remove prompts with a keep default on complete torrents", %{tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "rm", 1)
    base = Path.join(tmp, "rm")
    id = add_seeded(path, base, raw_info, data)

    kept =
      capture_io("\n", fn ->
        @task.run(["remove", id])
      end)

    assert kept =~ "kept #{id}"
    assert File.exists?(Path.join(base, "rm.bin"))

    gone =
      capture_io(fn ->
        @task.run(["remove", id, "--yes"])
      end)

    assert gone =~ "removed #{id} (2 file(s))"
    refute File.exists?(Path.join(base, "rm.bin"))
  end

  test "remove prompts with a delete default on incomplete torrents", %{tmp: tmp} do
    {path, _info, _data} = craft(tmp, "rmi", 1)
    base = Path.join(tmp, "rmi")
    {:ok, id} = Session.add_torrent(path, base_dir: base, peers: [blackhole()])
    on_exit(fn -> Session.forget(id) end)
    await_status(Session, id, :downloading)

    output =
      capture_io("y\n", fn ->
        @task.run(["remove", id])
      end)

    assert output =~ "removed #{id}"
    assert [] = Session.status() |> Enum.filter(&(&1.id == id))
  end

  test "remove dry-run lists without deleting", %{tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "rmd", 1)
    base = Path.join(tmp, "rmd")
    id = add_seeded(path, base, raw_info, data)

    output =
      capture_io(fn ->
        @task.run(["remove", id, "--dry-run"])
      end)

    assert output =~ "would delete 2 file(s)"
    assert output =~ "rmd.bin"

    assert {:ok, _} = Session.forget(id)
  end

  # The task's own add announces through the stubbed requests seam (fake
  # peers that never complete), so the download polls until killed.
  defp task_added_id(path) do
    Enum.find(Session.status(), &(&1.path == path)).id
  end

  test "download polls until the entry leaves downloading", %{tmp: tmp} do
    {path, _info, _data} = craft(tmp, "poll", 1)
    base = Path.join(tmp, "poll")

    pid = spawn(fn -> @task.run(["download", path, "--dir", base]) end)
    Process.sleep(2_500)
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
    Session.forget(task_added_id(path))
  end

  test "download raises when the entry vanishes mid-poll", %{tmp: tmp} do
    {path, _info, _data} = craft(tmp, "gone", 1)
    base = Path.join(tmp, "gone")

    pid = spawn(fn -> @task.run(["download", path, "--dir", base]) end)
    ref = Process.monitor(pid)
    Process.sleep(1_500)
    assert {:ok, _} = Session.forget(task_added_id(path))

    assert_receive {:DOWN, ^ref, :process, ^pid, {%Mix.Error{message: "torrent gone" <> _}, _}},
                   5_000
  end

  test "remove accepts explicit yes and rejects other answers", %{tmp: tmp} do
    {path, raw_info, data} = craft(tmp, "rmy", 1)
    base = Path.join(tmp, "rmy")
    id = add_seeded(path, base, raw_info, data)

    capture_io("yes\n", fn -> @task.run(["remove", id]) end)
    assert [] = Session.status() |> Enum.filter(&(&1.id == id))

    {path2, raw_info2, data2} = craft(tmp, "rmn", 1)
    base2 = Path.join(tmp, "rmn")
    id2 = add_seeded(path2, base2, raw_info2, data2)

    kept = capture_io("maybe\n", fn -> @task.run(["remove", id2]) end)
    assert kept =~ "kept #{id2}"
    assert {:ok, _} = Session.forget(id2)
  end

  test "remove of an unknown torrent raises" do
    assert_raise Mix.Error, ~r/not_found/, fn -> @task.run(["remove", "nope", "--yes"]) end
    assert_raise Mix.Error, ~r/usage/, fn -> @task.run(["remove"]) end
  end
end
