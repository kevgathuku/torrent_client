defmodule Torrent do
  defstruct [:announce, :name, :length, :pieces, :piece_length, :info_hash]

  @doc """
  Convert from a bento torrent struct to our own torrent struct
  """
  def from_bento(bento_torrent, opts) do
    bento_torrent
    |> Map.take([:announce])
    |> Map.put(:name, bento_torrent.info.name)
    |> Map.put(:length, remaining(bento_torrent))
    |> Map.put(:info_hash, info_hash(bento_torrent))
    |> Map.put(:piece_length, Map.get(bento_torrent.info, :"piece length"))
    |> Map.put(:pieces, bento_torrent.info.pieces)
    |> Map.merge(opts)
  end

  @doc """
  Get the remaining length from a Bento torrent file
  Handles both single file torrents and multi-file torrents
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

  def info_hash(bento_torrent) do
    bento_torrent.info
    |> Map.take([:name, :length, :"piece length", :pieces])
    |> Bento.encode!()
    |> sha_sum()
  end

  defp sha_sum(binary) do
    :crypto.hash(:sha, binary)
  end
end
