defmodule Tracker do
  @moduledoc """
  Tracker HTTP edge and response parsing. Announce tiers come from
  `Torrent.announce_tiers/1`; peer lists parse into `Peer` structs.
  """
  @doc """
  Returns the Tracker URL with correctly encoded params
  """
  def tracker_url(base_url, bento_torrent, info_hash, peer_id, port, opts \\ []) do
    params =
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
      |> maybe_put(:event, Keyword.get(opts, :event))
      |> maybe_put(:key, Keyword.get(opts, :key))
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{encode_param(to_string(value))}" end)

    "#{base_url}?#{params}"
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

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
    case Bento.decode(body) do
      {:ok, %{"failure reason" => reason}} ->
        {:error, reason}

      {:ok, decoded} when is_map(decoded) ->
        with {:ok, peers} <- parse_peers(decoded) do
          {:ok, %{peers: peers, interval: response_interval(decoded)}}
        end

      {:ok, _} ->
        {:error, "Unknown response from tracker"}

      {:error, _} ->
        {:error, :malformed_response}
    end
  end

  defp parse_peers(decoded) do
    if Map.has_key?(decoded, "peers") or Map.has_key?(decoded, "peers6") do
      with {:ok, v4} <- parse_family(decoded, "peers", :ipv4),
           {:ok, v6} <- parse_family(decoded, "peers6", :ipv6) do
        {:ok, Peer.filter_usable(v4 ++ v6)}
      end
    else
      {:error, "Unknown response from tracker"}
    end
  end

  # Tracker-supplied re-announce interval in seconds; 0 means "use our own".
  defp response_interval(%{"interval" => interval}) when is_integer(interval) and interval >= 0 do
    interval
  end

  defp response_interval(_decoded), do: 0

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
        case Peer.parse_address(ip) do
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
