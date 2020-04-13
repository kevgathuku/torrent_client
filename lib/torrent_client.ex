defmodule TorrentClient do
  @moduledoc """
  Documentation for TorrentClient.
  """

  def parse(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def sample() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent")
  end
end
