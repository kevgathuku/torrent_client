defmodule Tracker do
  use Tesla

  @port 6882
  @peer_id Utils.generate_peer_id()

  @doc """
  Returns the Tracker URL with the params attached
  """
  def tracker_url(bento_torrent) do
    params =
      %{
        info_hash: Torrent.info_hash(bento_torrent),
        peer_id: @peer_id,
        # The port number this peer is listening on.
        port: @port,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: Torrent.remaining(bento_torrent)
      }
      |> URI.encode_query()

    "#{bento_torrent.announce}?#{params}"
  end

  def request_peers(bento_torrent) do
    bento_torrent
    |> tracker_url()
    |> get()
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
  """
  def peers(bento_torrent) do
    # TODO: Add error handling for the request_peers request
    {:ok, response} =
      bento_torrent
      |> request_peers()

    parse_peer_response(response)
  end

  @doc """
  Get a random peer from the list of parsed Peers
  """
  def random_peer(bento_torrent) do
    bento_torrent
    |> peers()
    |> Enum.random()
  end

  @doc """
  Generate a handshake message to send to peers
  """
  def handshake_message(torrent) do
    capabilities = <<0, 0, 0, 0, 0, 0, 0, 0>>
    info_hash = torrent.info_hash
    protocol = "BitTorrent Protocol"
    protocol_length = byte_size(protocol)

    <<protocol_length>> <> protocol <> capabilities <> info_hash <> @peer_id
  end
end
