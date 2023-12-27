defmodule DownloaderTest do
  use ExUnit.Case, async: true

  setup context do
    case context do
      # If torrent_file_path is available in the context
      %{torrent_file_path: torrent_file_path} ->
        server = start_supervised!({Downloader, [torrent_file_path]})
        # Context to be available to tests
        %{server: server}

      _ ->
        # We can simply return :ok when we don't want to add any extra metadata
        :ok
    end
  end

  test "parses single file torrent to a bento torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(Utils.single_file_torrent())

    assert bento_torrent.__struct__ == Bento.Metainfo.Torrent
    assert bento_torrent.info.__struct__ == Bento.Metainfo.SingleFile
  end

  test "parses multi file torrent to a bento torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(Utils.multi_file_torrent())

    assert bento_torrent.__struct__ == Bento.Metainfo.Torrent
    assert bento_torrent.info.__struct__ == Bento.Metainfo.MultiFile
  end

  test "returns error for a non-existent torrent file" do
    refute match?({:ok, _}, Downloader.parse_torrent_file("mypath"))
  end

  @tag torrent_file_path: Utils.single_file_torrent()
  test "process starts when provided a valid single file torrent path", %{server: server} do
    state = :sys.get_state(server)

    assert state.bento_torrent.__struct__ == Bento.Metainfo.Torrent
  end

  @tag torrent_file_path: Utils.multi_file_torrent()
  test "process starts when provided a valid multi file torrent path", %{server: server} do
    state = :sys.get_state(server)

    assert state.bento_torrent.__struct__ == Bento.Metainfo.Torrent
  end

  test "exits when provided an invalid torrent file path" do
    Process.flag(:trap_exit, true)
    pid = spawn_link(fn -> Downloader.start_link("wrong_path") end)

    assert_receive {:EXIT, ^pid, :shutdown}
  end
end
