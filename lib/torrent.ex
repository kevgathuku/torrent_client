defmodule Torrent do
  @hash_length 20

  def get_piece_hashes(%{info: %{pieces: pieces}}) when byte_size(pieces) < 20,
    do: {:error, "Received malformed pieces. Length: #{byte_size(pieces)}"}

  def get_piece_hashes(%{info: %{pieces: pieces}}) do
    pieces_length = byte_size(pieces)

    num_hashes = div(pieces_length, @hash_length)

    for i <- 0..(num_hashes - 1), do: binary_part(pieces, i, 20)
  end

  @doc """
  True when the data hashes to the expected 20-byte SHA1.
  """
  def verify_hash?(data, expected_hash) when is_binary(data) and is_binary(expected_hash) do
    Utils.sha_sum(data) == expected_hash
  end

  @doc """
  Get the remaining length from a Bento torrent file
  Handles both single file torrents and multi-file torrents
  """
  def remaining(bento_torrent) do    case bento_torrent.info do
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

  @doc """
  Compute the info hash from a Bento torrent file
  Handles both single file torrents and multi-file torrents
  """
  def info_hash(bento_torrent) do
    bento_torrent
    |> bencode_info()
    |> Bento.encode!()
    |> Utils.sha_sum()
    |> Base.encode16()
  end

  defp bencode_info(bento_torrent) do
    case bento_torrent.info do
      %Bento.Metainfo.SingleFile{} ->
        bento_torrent.info
        |> Map.take([:name, :pieces, :"piece length", :length])

      %Bento.Metainfo.MultiFile{} ->
        bento_torrent.info
        |> Map.take([:name, :pieces, :"piece length", :files])
    end
  end
end
