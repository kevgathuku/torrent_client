defmodule TorrentTest do
  use ExUnit.Case, async: true

  @multi_file_torrent Utils.multi_file_torrent()
  @single_file_torrent Utils.single_file_torrent()

  test "calculates the correct info hash for single file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@single_file_torrent)
    info_hash = Torrent.info_hash(bento_torrent)

    # debian-12.4.0-amd64-netinst.iso.torrent
    assert info_hash == "8FFEAE56C32AB54D9992E4CBB20EF070637A9C72"
  end

  test "calculates the correct info hash for multi file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@multi_file_torrent)
    info_hash = Torrent.info_hash(bento_torrent)

    # big-buck-bunny.torrent
    assert info_hash == "DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C"
  end

  test "get piece hashes for a single file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@single_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end

  test "get piece hashes for a multi file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@multi_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end
end
