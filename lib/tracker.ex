defmodule Tracker do
  @moduledoc """
  Tracker HTTP edge and response parsing. Announce tiers come from
  `Torrent.announce_tiers/1`; peer lists parse into `Peer` structs.
  """
  @doc """
  Returns the Tracker URL with correctly encoded params
  """
  def tracker_url(bento_torrent, info_hash, peer_id, port) do
    info_hash = info_hash |> Base.decode16!()

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

  def parse_peer_response(body) do
    case Bento.decode!(body) do
      %{"failure reason" => reason} ->
        {:error, reason}

      decoded when is_map(decoded) ->
        parse_peers(decoded)

      _ ->
        {:error, "Unknown response from tracker"}
    end
  end

  defp parse_peers(decoded) do
    if Map.has_key?(decoded, "peers") or Map.has_key?(decoded, "peers6") do
      with {:ok, v4} <- parse_family(decoded, "peers", :ipv4),
           {:ok, v6} <- parse_family(decoded, "peers6", :ipv6) do
        {:ok, %{peers: v4 ++ v6}}
      end
    else
      {:error, "Unknown response from tracker"}
    end
  end

  defp parse_family(decoded, key, family) do
    case Map.get(decoded, key) do
      nil -> {:ok, []}
      peers when is_binary(peers) -> Peer.parse_compact(peers, family)
      _ -> {:error, "Invalid #{key} in tracker response"}
    end
  end
end
