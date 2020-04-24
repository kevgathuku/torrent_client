defmodule TorrentClient do
  @moduledoc """
  Documentation for TorrentClient.
  """

  def parse(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def sample() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent")
    |> Tracker.request_peers()
    |> Tracker.parse_peer_response()

    # %Bento.Metainfo.Torrent{
    #   announce: "http://bttracker.debian.org:6969/announce",
    #   "announce-list": nil,
    #   comment: "\"Debian CD from cdimage.debian.org\"",
    #   "created by": nil,
    #   "creation date": 1581169128,
    #   encoding: nil,
    #   info: %Bento.Metainfo.SingleFile{
    #     length: 351272960,
    #     md5sum: nil,
    #     name: "debian-10.3.0-amd64-netinst.iso",
    #     "piece length": 262144,
    #     pieces: <<94, 148, 194, 28, 23, 146, 140, 77, 129, 109, 87, 182, 105, 67,
    #       105, 94, 233, 62, 117, 113, 53, 213, 123, 174, 189, 1, 244, 116, 147, 185,
    #       62, 16, 241, 51, 140, 35, 148, 17, ...>>,
    #     private: nil
    #   }
    # }
  end
end
