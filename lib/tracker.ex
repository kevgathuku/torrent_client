defmodule Tracker do
  @doc """
  Returns the Tracker URL with correctly encoded params
  """
  @peer_chunk_size 6

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

  defp extract_peers(data) when is_binary(data) and rem(byte_size(data), @peer_chunk_size) == 0 do
    chunk_binary(data, @peer_chunk_size, [])
  end

  def chunk_binary(<<>>, _chunk_size, acc) do
    Enum.map(acc, &Peer.build_peer/1)
  end

  def chunk_binary(binary, chunk_size, acc) do
    <<ip::binary-size(chunk_size), rest::binary>> = binary

    chunk_binary(rest, chunk_size, [ip | acc])
  end
end
