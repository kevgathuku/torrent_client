defmodule Tracker do
  use Tesla

  def request_peers(torrent) do
    torrent
    |> Torrent.tracker_url()
    |> get!()
  end

  def parse_peer_response(response) do
    response.body
    |> Bento.decode!()
    |> Map.get("peers")
    |> Peer.extract_peers()
  end
end
