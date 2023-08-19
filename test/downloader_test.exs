defmodule DownloaderTest do
  use ExUnit.Case

  @test_torrent_file Utils.test_torrent_file
  @test_torrent_name "signofthecross_1309_librivox"
  @hash_length 20

  # test "parses a single file torrent" do
  #   subject = Downloader.to_bento_torrent(@test_torrent_file)

  #   assert subject.__struct__ == Bento.Metainfo.Torrent
  #   assert subject.info.__struct__ == Bento.Metainfo.SingleFile
  #   assert subject.info.name == @test_torrent_name
  # end

  test "converts torrent file to a bento torrent" do
    bento_torrent = Downloader.to_bento_torrent(@test_torrent_file)

    assert bento_torrent.__struct__ == Bento.Metainfo.Torrent
    assert bento_torrent.info.__struct__ == Bento.Metainfo.MultiFile
  end

  test "converts torrent file to custom torrent" do
    bento_torrent = Downloader.to_bento_torrent(@test_torrent_file)
    torrent_struct = Downloader.to_own_torrent(@test_torrent_file)

    assert torrent_struct.__struct__ == Torrent
    assert torrent_struct.name == @test_torrent_name
    assert byte_size(torrent_struct.info_hash) == @hash_length
    assert length(torrent_struct.piece_hashes) == byte_size(bento_torrent.info.pieces) / @hash_length
  end
end
