defmodule TorrentClient do
  @moduledoc """
  Documentation for TorrentClient.
  """

  def parse(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def peers() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent")
    |> Tracker.request_peers()
    |> Tracker.parse_peer_response()
  end

  def sample_bento() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent")
  end

  def sample_torrent() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent") |> Torrent.from_bento()
  end
end
