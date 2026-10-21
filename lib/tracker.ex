defmodule Tracker do
  @moduledoc """
  Tracker HTTP edge and response parsing. Announce tiers come from
  `Torrent.announce_tiers/1`; peer lists parse into `Peer` structs.
  """
  @doc """
  Returns the Tracker URL with correctly encoded params
  """
  def tracker_url(base_url, bento_torrent, info_hash, peer_id, port) do
    query =
      %{
        info_hash: Base.decode16!(info_hash),
        peer_id: peer_id,
        # The port number this peer is listening on.
        port: port,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: Torrent.remaining(bento_torrent)
      }
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{encode_param(to_string(value))}" end)

    "#{base_url}?#{query}"
  end

  # Byte-wise percent-encoding (RFC 3986): default query encoders render
  # space as `+`, corrupting binary hashes that contain 0x20.
  defp encode_param(bytes) do
    for <<byte <- bytes>>, into: "" do
      if byte in ?0..?9 or byte in ?a..?z or byte in ?A..?Z or byte in ~c"-_.~" do
        <<byte>>
      else
        "%" <> Base.encode16(<<byte>>)
      end
    end
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
      peers when is_list(peers) -> parse_dict_peers(peers)
      _ -> {:error, "Invalid #{key} in tracker response"}
    end
  end

  defp parse_dict_peers(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      %{"ip" => ip, "port" => port}, {:ok, acc} when is_binary(ip) and is_integer(port) ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, tuple} -> {:cont, {:ok, [%Peer{ip_tuple: tuple, port: port} | acc]}}
          {:error, _} -> {:halt, {:error, :unparseable_peer_address}}
        end

      _entry, _acc ->
        {:halt, {:error, :malformed_peer_entry}}
    end)
    |> case do
      {:ok, peers} -> {:ok, Enum.reverse(peers)}
      error -> error
    end
  end
end
