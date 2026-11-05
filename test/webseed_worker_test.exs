defmodule BoomDisk do
  @moduledoc false
  def write_piece(_base, _info, _index, _data), do: {:error, :boom}
end

# Plain http doubles, not Mox: fetch tasks are separate processes and Mox
# cannot see private expectations across the GenServer/task boundary.
# Fixed payloads keep every test deterministic with no shared state.
defmodule FixedHttp do
  @moduledoc false
  @data :binary.copy(<<7>>, 32_768)
  def data, do: @data
  def get(_url, _headers), do: {:ok, %Tesla.Env{status: 206, body: @data}}
end

defmodule BadHttp do
  @moduledoc false
  def get(_url, _headers),
    do: {:ok, %Tesla.Env{status: 206, body: :binary.copy(<<8>>, 32_768)}}
end

defmodule RefusedHttp do
  @moduledoc false
  def get(_url, _headers), do: {:error, :econnrefused}
end

defmodule CheckedHttp do
  @moduledoc false
  # Accepts only the exact request the success test makes; anything
  # else is a loud failure, so the test pins the worker's request.
  def get("https://x/f.bin", [{"range", "bytes=0-32767"}]),
    do: {:ok, %Tesla.Env{status: 206, body: FixedHttp.data()}}
end

defmodule SlowHttp do
  @moduledoc false
  # Rendezvous double: notifies the test when the fetch starts and holds
  # it open until released, so cancels land in flight deterministically.
  # The gate lives in WebseedStub, keyed by URL (one per test).
  def get(url, _headers) do
    case WebseedStub.await_gate(url) do
      :ok -> {:ok, %Tesla.Env{status: 206, body: FixedHttp.data()}}
      {:error, _} = err -> err
    end
  end
end

defmodule WebseedWorkerTest do
  use ExUnit.Case, async: true

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  alias TorrentClient.{Disk, WebseedWorker}

  @piece_length 32_768

  setup do
    base = Path.join(System.tmp_dir!(), "kog11-webseed-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    info = %{:"piece length" => @piece_length, name: "f.bin", length: @piece_length}
    :ok = Disk.init_layout(base, info)

    %{base: base, info: info, data: FixedHttp.data(), hash: :crypto.hash(:sha, FixedHttp.data())}
  end

  defp worker_opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        webseed_urls: ["https://x/f.bin"],
        info: ctx.info,
        piece_index: 0,
        piece_hash: ctx.hash,
        base_dir: ctx.base,
        http: FixedHttp,
        disk: Disk,
        report_to: self()
      ],
      extra
    )
  end

  defp monitor_start(opts) do
    {:ok, pid} = WebseedWorker.start_link(opts)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  test "verified fetch writes the piece and reports completion", ctx do
    {pid, ref} = monitor_start(worker_opts(ctx, http: CheckedHttp))

    assert_receive {:block_progress, 0}, 5_000
    assert_receive {:piece_complete, ^pid, 0}, 5_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
  end

  test "hash mismatch stops abnormally and writes nothing", ctx do
    {_pid, ref} = monitor_start(worker_opts(ctx, http: BadHttp))

    assert_receive {:DOWN, ^ref, :process, _, :piece_mismatch}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "fetch failure stops with the webseed reason", ctx do
    {_pid, ref} = monitor_start(worker_opts(ctx, http: RefusedHttp))

    assert_receive {:DOWN, ^ref, :process, _, {:webseed_error, :webseed_failed}}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "cancel in flight drops the bytes instead of writing them", ctx do
    # The gate holds the fetch open: cancel lands before release, always.
    url = "https://x/cancel"
    gate = WebseedStub.open_gate(url)
    {pid, mon} = monitor_start(worker_opts(ctx, http: SlowHttp, webseed_urls: [url]))

    assert_receive {:fetch_started, task, ^gate}, 5_000
    send(pid, {:cancel_piece, 0})
    send(task, {:release, gate})

    assert_receive {:DOWN, ^mon, :process, _, :normal}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "unknown piece stops without fetching", ctx do
    assert {:error, :invalid_piece} = WebseedWorker.start_link(worker_opts(ctx, piece_index: 9))
  end

  test "disk failure stops abnormally", ctx do
    {_pid, ref} = monitor_start(worker_opts(ctx, disk: BoomDisk))

    assert_receive {:DOWN, ^ref, :process, _, {:disk_error, :boom}}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "no report_to still writes and stops normally", ctx do
    {_pid, ref} = monitor_start(Keyword.put(worker_opts(ctx), :report_to, nil))

    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
  end

  test "stale cancel indices are ignored", ctx do
    url = "https://x/stale"
    gate = WebseedStub.open_gate(url)
    {pid, mon} = monitor_start(worker_opts(ctx, http: SlowHttp, webseed_urls: [url]))

    assert_receive {:fetch_started, task, ^gate}, 5_000
    send(pid, {:cancel_piece, 7})
    send(task, {:release, gate})

    assert_receive {:piece_complete, ^pid, 0}, 5_000
    assert_receive {:DOWN, ^mon, :process, _, :normal}, 5_000
  end
end
