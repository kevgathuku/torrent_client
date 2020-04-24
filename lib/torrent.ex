defmodule Torrent do
  defstruct [:announce, :info_hash, :name, :length, :piece_hashes, :piece_length]

  @doc """
  Returns the Tracker URL with the params attached
  """
  def tracker_url(torrent) do
    params =
      %{
        info_hash: info_hash(torrent),
        peer_id: Utils.generate_peer_id(),
        # The port number this peer is listening on.
        port: 6882,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: remaining(torrent)
      }
      |> URI.encode_query()

    "#{torrent.announce}?#{params}"
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

  defp info_hash(torrent) do
    torrent.info
    |> Map.from_struct()
    |> Map.take([:name, :length, :"piece length", :pieces])
    |> Bento.encode!()
    |> sha_sum()
  end

  defp sha_sum(binary) do
    :crypto.hash(:sha, binary)
  end
end

# TorrentFile{
# 	Announce:    bto.Announce,
# 	InfoHash:    infoHash, #  computed the SHA-1 hash of the entire bencoded info dict
# 	PieceHashes: pieceHashes, # a slice of hashes (each [20]byte) to enable easily accessing individual hashes
# 	PieceLength: bto.Info.PieceLength,
# 	Length:      bto.Info.Length,
# 	Name:        bto.Info.Name,
# }
