defmodule Torrent do
  defstruct [:announce, :name, :length, :piece_hashes, :piece_length, :info_hash]

  @doc """
  Convert from a bento torrent struct to our own torrent struct
  """
  def from_bento(bento_torrent) do
    struct(Torrent)
    |> Map.put(:announce, bento_torrent.announce)
    |> Map.put(:name, bento_torrent.info.name)
    |> Map.put(:length, remaining(bento_torrent))
    |> Map.put(:info_hash, info_hash(bento_torrent))
    |> Map.put(:piece_length, Map.get(bento_torrent.info, :"piece length"))
    |> Map.put(:piece_hashes, split_pieces_hash(bento_torrent.info.pieces))
  end

  @spec split_pieces_hash(bitstring) :: list | {:error, <<_::64, _::_*8>>}
  def split_pieces_hash(pieces) when byte_size(pieces) < 20,
    do: {:error, "Received malformed pieces. Length: #{byte_size(pieces)}"}

  def split_pieces_hash(pieces) do
    hash_length = 20
    pieces_length = byte_size(pieces)

    num_hashes = div(pieces_length, hash_length)

    for i <- 0..(num_hashes - 1), do: binary_part(pieces, i, 20)
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

  def bencode_info(bento_torrent) do
    # TODO: Single file for now
    # Check how to do this correctly for multi-file torrents also
    bento_torrent.info
    |> Map.take([:name, :pieces, :"piece length", :length])
  end

  @spec info_hash(atom | %{:info => any, optional(any) => any}) :: any
  def info_hash(bento_torrent) do
    bento_torrent
    |> bencode_info()
    |> Bento.encode!()
    |> Utils.sha_sum()
    |> Base.encode16()
  end
end
