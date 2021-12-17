defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

  @port 6882
  @peer_id Utils.generate_peer_id()

  def parse_torrent_file(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def test_file do
    "test/_data/debian-10.2.0-amd64-netinst.iso.torrent"
  end

  def sample_bento_torrent() do
    test_file()
    |> parse_torrent_file()
  end

  def tracker_peers() do
    sample_bento_torrent() |> Torrent.from_bento() |> Tracker.peers(@peer_id, @port)
  end
end
