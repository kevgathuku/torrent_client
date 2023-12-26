defmodule DownloaderTest do
  use ExUnit.Case, async: true

  test "parses single file torrent to a bento torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(Utils.single_file_torrent)

    assert bento_torrent.__struct__ == Bento.Metainfo.Torrent
    assert bento_torrent.info.__struct__ == Bento.Metainfo.SingleFile
  end

  test "parses multi file torrent to a bento torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(Utils.multi_file_torrent)

    assert bento_torrent.__struct__ == Bento.Metainfo.Torrent
    assert bento_torrent.info.__struct__ == Bento.Metainfo.MultiFile
  end

  test "returns error for a non-existent torrent file" do
    {:error, _} = Downloader.parse_torrent_file("mypath")
  end
end
