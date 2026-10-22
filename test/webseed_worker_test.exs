defmodule BoomDisk do
  @moduledoc false
  def write_piece(_base, _info, _index, _data), do: {:error, :boom}
end

defmodule WebseedWorkerTest do
  use ExUnit.Case, async: true

  import Mox
  setup :set_mox_private
  setup :verify_on_exit!

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
    data = :crypto.strong_rand_bytes(@piece_length)

    %{base: base, info: info, data: data, hash: :crypto.hash(:sha, data)}
  end

  defp worker_opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        webseed_urls: ["https://x/f.bin"],
        info: ctx.info,
        piece_index: 0,
        piece_hash: ctx.hash,
        base_dir: ctx.base,
        http: TorrentClient.WebseedHttpMock,
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
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn "https://x/f.bin", [{"range", "bytes=0-32767"}] ->
      {:ok, %Tesla.Env{status: 206, body: ctx.data}}
    end)

    {pid, ref} = monitor_start(worker_opts(ctx))

    assert_receive {:block_progress, 0}, 5_000
    assert_receive {:piece_complete, ^pid, 0}, 5_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
  end

  test "hash mismatch stops abnormally and writes nothing", ctx do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers ->
      {:ok, %Tesla.Env{status: 206, body: :crypto.strong_rand_bytes(@piece_length)}}
    end)

    {_pid, ref} = monitor_start(worker_opts(ctx))

    assert_receive {:DOWN, ^ref, :process, _, :piece_mismatch}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "fetch failure stops with the webseed reason", ctx do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers -> {:error, :econnrefused} end)

    {_pid, ref} = monitor_start(worker_opts(ctx))

    assert_receive {:DOWN, ^ref, :process, _, {:webseed_error, :webseed_failed}}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "cancel in flight drops the bytes instead of writing them", ctx do
    test = self()

    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers ->
      send(test, :fetching)
      assert_receive :go, 5_000
      {:ok, %Tesla.Env{status: 206, body: ctx.data}}
    end)

    {pid, ref} = monitor_start(worker_opts(ctx))

    assert_receive :fetching, 5_000
    send(pid, {:cancel_piece, 0})
    send(pid, :go)

    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "unknown piece stops without fetching", ctx do
    assert {:error, :invalid_piece} = WebseedWorker.start_link(worker_opts(ctx, piece_index: 9))
  end

  test "disk failure stops abnormally", ctx do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers -> {:ok, %Tesla.Env{status: 206, body: ctx.data}} end)

    {_pid, ref} = monitor_start(worker_opts(ctx, disk: BoomDisk))

    assert_receive {:DOWN, ^ref, :process, _, {:disk_error, :boom}}, 5_000
    refute_received {:piece_complete, _, 0}
  end

  test "no report_to still writes and stops normally", ctx do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers -> {:ok, %Tesla.Env{status: 206, body: ctx.data}} end)

    {_pid, ref} = monitor_start(Keyword.put(worker_opts(ctx), :report_to, nil))

    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
  end

  test "stale cancel indices are ignored", ctx do
    test = self()

    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers ->
      send(test, :fetching)
      assert_receive :go, 5_000
      {:ok, %Tesla.Env{status: 206, body: ctx.data}}
    end)

    {pid, ref} = monitor_start(worker_opts(ctx))

    assert_receive :fetching, 5_000
    send(pid, {:cancel_piece, 7})
    send(pid, :go)

    assert_receive {:piece_complete, ^pid, 0}, 5_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
  end
end
