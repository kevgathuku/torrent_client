defmodule Torrent do
  defstruct [:announce, :name, :length, :pieces, :piece_length, :info_hash]

  @port 6882
  @peer_id Utils.generate_peer_id()

  @doc """
  Convert from a bento torrent struct to our own torrent struct
  """
  def from_bento(bento_torrent) do
    bento_torrent
    |> Map.take([:announce])
    |> Map.put(:name, bento_torrent.info.name)
    |> Map.put(:length, bento_torrent.info.length)
    |> Map.put(:info_hash, info_hash(bento_torrent))
    |> Map.put(:piece_length, Map.get(bento_torrent.info, :"piece length"))
    |> Map.put(:pieces, bento_torrent.info.pieces)
  end

  @doc """
  Returns the Tracker URL with the params attached
  """
  def tracker_url(bento_torrent) do
    params =
      %{
        info_hash: info_hash(bento_torrent),
        peer_id: @peer_id,
        # The port number this peer is listening on.
        port: @port,
        uploaded: "0",
        downloaded: "0",
        # use the compact peer format
        compact: "1",
        left: remaining(bento_torrent)
      }
      |> URI.encode_query()

    "#{bento_torrent.announce}?#{params}"
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

  @doc """
  Get the remaining length from a torrent file
  Works for both single file torrents and multi-file torrents
  """
  def remaining(bento_torrent) do
    case bento_torrent.info do
      %Bento.Metainfo.SingleFile{} ->
        bento_torrent.info.length

      %Bento.Metainfo.MultiFile{} ->
        Enum.reduce(bento_torrent.info.files, 0, fn file, acc ->
          acc + file.length
        end)

      _ ->
        0
    end
  end

  defp info_hash(bento_torrent) do
    bento_torrent.info
    |> Map.take([:name, :length, :"piece length", :pieces])
    |> Bento.encode!()
    |> sha_sum()
  end

  defp sha_sum(binary) do
    :crypto.hash(:sha, binary)
  end
end
