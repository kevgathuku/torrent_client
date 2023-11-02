defmodule Tracker do
  use Tesla

  # TODO: Should this be a Genserver module?

  @spec get_peers(
          Torrent.t(),
          String.t(),
          integer()
        ) :: {:error, any} | {:ok, list}
  @doc """
  Request the peers from the tracker using the custom torrent file
  Accepts our custom Torrent struct
  """
  def get_peers(torrent, peer_id, port) do
    case get(tracker_url(torrent, peer_id, port)) do
      {:ok, response} ->
        parse_peer_response(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec tracker_url(
          Torrent.t(),
          String.t(),
          integer()
        ) :: nonempty_binary
  @doc """
  Returns the Tracker URL with the params attached
  Accepts our custom Torrent struct
  """
  def tracker_url(torrent, peer_id, port) do
    params =
      %{
        info_hash: torrent.info_hash,
        peer_id: peer_id,
        # The port number this peer is listening on.
        port: port,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: torrent.length
      }
      |> URI.encode_query()

    "#{torrent.announce}?#{params}"
  end

  defp parse_peer_response(response) do
    decoded_response = Bento.decode!(response.body)

    case decoded_response do
      %{"failure reason" => reason} ->
        {:error, reason}

      %{"peers" => peers} ->
        {:ok, extract_peers(peers)}

      _ ->
        {:error, "Unknown response from tracker"}
    end
  end

  @spec extract_peers(binary) :: list
  defp extract_peers(data) when is_binary(data) do
    peer_size = 6
    num_peers = floor(byte_size(data) / peer_size)

    # Extract peers from the binary data into a list of peers
    Enum.reduce(0..(num_peers - 1), [], fn index, acc ->
      List.insert_at(acc, index, binary_part(data, index * peer_size, peer_size))
    end)
    |> Enum.map(&Peer.parse_peer/1)
  end
end
