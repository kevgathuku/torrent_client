defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

  @port 6882
  @peer_id Utils.generate_peer_id()

  def to_bento_torrent(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def test_file do
    "test/_data/debian-10.2.0-amd64-netinst.iso.torrent"
  end

  def sample_torrent() do
    test_file()
    |> to_bento_torrent()
    |> Torrent.from_bento(%{peer_id: @peer_id})
  end

  def tracker_peers() do
    sample_torrent() |> Tracker.peers(@peer_id, @port)
  end
end
