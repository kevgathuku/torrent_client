defmodule Tracker do
  @doc """
  Returns the Tracker URL with correctly encoded params
  """
  def tracker_url(bento_torrent, peer_id, port) do
    info_hash = Torrent.info_hash(bento_torrent) |> Base.decode16!()

    params =
      %{
        info_hash: info_hash,
        peer_id: peer_id,
        # The port number this peer is listening on.
        port: port,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: Torrent.remaining(bento_torrent)
      }
      |> URI.encode_query()

    "#{bento_torrent.announce}?#{params}"
  end

  @doc """
  Request the peers from the tracker
  """
  def get_peers(tracker_url) do
    case Tesla.get(tracker_url) do
      {:ok, %{body: body}} ->
        parse_peer_response(body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_peer_response(body) do
    case Bento.decode!(body) do
      %{"failure reason" => reason} ->
        {:error, reason}

      %{"peers" => peers} ->
        {:ok, %{peers: extract_peers(peers)}}

      _ ->
        {:error, "Unknown response from tracker"}
    end
  end

  @spec extract_peers(binary) :: list
  defp extract_peers(data) when is_binary(data) do
    peer_size = 6
    num_peers = floor(byte_size(data) / peer_size)

    # Extract peers from the binary data into a list of peers
    # TODO: Can be made more declarative -> chunk_every??
    Enum.reduce(0..(num_peers - 1), [], fn index, acc ->
      List.insert_at(acc, index, binary_part(data, index * peer_size, peer_size))
    end)
    |> Enum.map(&Peer.build_peer/1)
  end
end
