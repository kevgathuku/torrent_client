defmodule TorrentClient.Tracker do
  use Tesla

  @doc """
  Returns the Tracker URL with the params attached
  """

  def build_tracker_url(torrent) do
    params =
      %{
        info_hash: info_hash(torrent),
        peer_id: generate_peer_id(),
        # The port number this peer is listening on.
        port: "6882",
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: remaining(torrent)
      }
      |> URI.encode_query()

    "#{torrent.announce}?#{params}"
  end

  def request_peers(torrent) do
    tracker_url = build_tracker_url(torrent)

    get(tracker_url)
  end

  @doc """
  Get the remaining length from a torrent file
  Works for both single file torrents and multi-file torrents
  """
  def remaining(torrent) do
    case torrent.info do
      %Bento.Metainfo.SingleFile{} ->
        torrent.info.length

      %Bento.Metainfo.MultiFile{} ->
        Enum.reduce(torrent.info.files, 0, fn file, acc ->
          acc + file.length
        end)

      _ ->
        0
    end
  end

  defp sha_sum(binary) do
    :crypto.hash(:sha, binary)
  end

  defp info_hash(torrent) do
    torrent.info
    |> Map.from_struct()
    |> Map.take([:name, :length, :"piece length", :pieces])
    |> Bento.encode!()
    |> sha_sum()
  end

  defp generate_peer_id() do
    :crypto.strong_rand_bytes(20) |> Base.encode64() |> binary_part(0, 20)
  end
end
