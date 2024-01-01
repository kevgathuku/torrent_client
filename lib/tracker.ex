defmodule Tracker do
  @peer_chunk_size 6

  require Logger

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
    case TorrentClient.Requests.Client.get(tracker_url) do
      {:ok, %{body: body} = response} ->
        Logger.debug("Got response from tracker: #{inspect(response)}")
        parse_peer_response(body)

      {:error, reason} ->
        Logger.debug("Error getting peers from tracker: #{reason}")
        {:error, reason}
    end
  end

  def parse_peer_response(body) do
    case Bento.decode!(body) do
      %{"failure reason" => reason} ->
        {:error, reason}

      %{"peers" => peers}
      when is_binary(peers) and rem(byte_size(peers), @peer_chunk_size) == 0 ->
        extracted_peers = extract_peers(peers, @peer_chunk_size, [])

        {:ok, %{peers: extracted_peers}}

      _ ->
        {:error, "Unknown response from tracker"}
    end
  end

  defp extract_peers(<<>>, _chunk_size, acc) do
    Enum.map(acc, &Peer.build_peer/1)
  end

  defp extract_peers(binary, chunk_size, acc) do
    <<ip::binary-size(chunk_size), rest::binary>> = binary

    extract_peers(rest, chunk_size, [ip | acc])
  end
end
