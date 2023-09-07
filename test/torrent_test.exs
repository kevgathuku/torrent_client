defmodule TorrentTest do
  use ExUnit.Case

  @test_torrent_file "test/_data/2718B3EC2A16AED3EF5A3DFD551EF7CCC5CC398B.torrent"

  # test "greets the world" do
  #   assert Torrent.from_bento() == :world
  # end
  test "calculates the correct info hash" do
    decoded_torrent = Downloader.to_bento_torrent(@test_torrent_file)
    # decoded_torrent = Torrent.from_bento()
    info_hash = Torrent.info_hash(decoded_torrent)
    assert info_hash == "2718B3EC2A16AED3EF5A3DFD551EF7CCC5CC398B"
  end
end
