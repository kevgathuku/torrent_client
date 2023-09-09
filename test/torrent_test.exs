defmodule TorrentTest do
  use ExUnit.Case

  @multi_file_torrent "test/_data/2718B3EC2A16AED3EF5A3DFD551EF7CCC5CC398B.torrent"
  @single_file_torrent "test/_data/debian-12.1.0-amd64-netinst.iso.torrent"

  test "calculates the correct info hash for single file torrent" do
    info_hash =
      Downloader.to_bento_torrent(@single_file_torrent)
      |> Torrent.info_hash()

    assert info_hash == "A9164E99D5181CFEF0C23C209334103619080908"
  end

  test "calculates the correct info hash for multi file torrent" do
    info_hash =
      Downloader.to_bento_torrent(@multi_file_torrent)
      |> Torrent.info_hash()

    assert info_hash == "2718B3EC2A16AED3EF5A3DFD551EF7CCC5CC398B"
  end
end
