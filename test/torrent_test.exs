defmodule TorrentTest do
  use ExUnit.Case, async: true

  @multi_file_torrent Utils.multi_file_torrent
  @single_file_torrent Utils.single_file_torrent

  test "calculates the correct info hash for single file torrent" do
    info_hash =
      Downloader.parse_torrent_file(@single_file_torrent)
      |> Torrent.info_hash()

    assert info_hash == "A9164E99D5181CFEF0C23C209334103619080908"
  end

  test "calculates the correct info hash for multi file torrent" do
    info_hash =
      Downloader.parse_torrent_file(@multi_file_torrent)
      |> Torrent.info_hash()

    assert info_hash == "2718B3EC2A16AED3EF5A3DFD551EF7CCC5CC398B"
  end

  test "get piece hashes for a single file torrent" do
    bento_torrent = Downloader.parse_torrent_file(Utils.single_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end

  test "get piece hashes for a multi file torrent" do
    bento_torrent = Downloader.parse_torrent_file(Utils.multi_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end
end
