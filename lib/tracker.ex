defmodule Tracker do
  use Tesla

  @port 6882
  @peer_id Utils.generate_peer_id()

  @doc """
  Returns the Tracker URL with the params attached
  Accepts our custom Torrent struct
  """
  def tracker_url(torrent) do
    params =
      %{
        info_hash: torrent.info_hash,
        peer_id: @peer_id,
        # The port number this peer is listening on.
        port: @port,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: torrent.length
      }
      |> URI.encode_query()

    "#{torrent.announce}?#{params}"
  end

  @doc """
  Extract peers from the tracker response's peers binary data
  """
  def extract_peers(data) when is_binary(data) do
    peer_size = 6
    num_peers = (byte_size(data) / peer_size) |> floor

    # Extract peers from the binary data into a list of peers
    Enum.reduce(0..(num_peers - 1), [], fn index, acc ->
      List.insert_at(acc, index, binary_part(data, index * peer_size, peer_size))
    end)
    |> Enum.map(&Peer.parse_peer/1)
  end

  def parse_peer_response(response) do
    response.body
    |> Bento.decode!()
    |> Map.get("peers")
    |> extract_peers()
  end

  @doc """
  Get the peers for the torrent file
  Accepts our custom Torrent struct
  """
  def peers(torrent) do
    # TODO: Add error handling for the request
    response =
      torrent
      |> tracker_url()
      |> get!()

    parse_peer_response(response)
  end

  @doc """
  Get a random peer from the list of parsed Peers
  Accepts our custom Torrent struct
  """
  def random_peer(torrent) do
    torrent
    |> peers()
    |> Enum.random()
  end
end
