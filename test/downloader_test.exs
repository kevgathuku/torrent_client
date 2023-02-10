defmodule DownloaderTest do
  use ExUnit.Case

  def debian_torrent_file() do
    "test/_data/debian-10.2.0-amd64-netinst.iso.torrent"
  end

  def debian_torrent_name() do
    "debian-10.2.0-amd64-netinst.iso"
  end

  test "parses a single file torrent" do
    subject = Downloader.to_bento_torrent(debian_torrent_file)

    assert subject.__struct__ == Bento.Metainfo.Torrent
    assert subject.info.__struct__ == Bento.Metainfo.SingleFile
    assert subject.info.name == debian_torrent_name
  end

  test "converts bento torrent to the custom torrent" do
    bento_torrent = Downloader.to_bento_torrent(debian_torrent_file)
    torrent_struct = Downloader.bento_to_torrent(bento_torrent)
    hash_length = 20

    assert torrent_struct.__struct__ == Torrent
    assert byte_size(torrent_struct.info_hash) == hash_length
    assert length(torrent_struct.piece_hashes) == byte_size(bento_torrent.info.pieces) / hash_length
    assert torrent_struct.name == debian_torrent_name
  end
end
