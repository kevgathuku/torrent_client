defmodule Torrent do
  @moduledoc """
  Pure torrent domain: info-hashes, piece math, tracker tiers, and trust
  boundary validators. No I/O, no processes.
  """

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
  Tracker tiers from the announce-list, dropping empty tiers. Falls back to
  the single announce URL when the list is absent or empty. UDP tiers pass
  through untouched for the UDP tracker to consume.
  """
  def announce_tiers(bento) do
    raw = Map.get(bento, :"announce-list") || []

    tiers =
      for tier when is_list(tier) <- List.wrap(raw),
          cleaned = Enum.filter(tier, &is_binary/1),
          cleaned != [] do
        cleaned
      end

    if tiers == [], do: [[bento.announce]], else: tiers
  end

  @doc """
  True when a block write fits the torrent's declared sizes: the piece
  exists, the data is non-empty, and begin+size stays inside the piece
  (the last piece may be short). Stale state must never survive a write.
  """
  def validate_block(info, index, begin, data)
      when is_map(info) and is_integer(index) and is_integer(begin) and is_binary(data) do
    piece_length = Map.get(info, :"piece length")
    total = info_total(info)

    with true <- is_integer(piece_length) and piece_length > 0 and total > 0,
         count = div(total + piece_length - 1, piece_length),
         true <- index in 0..(count - 1)//1,
         size = byte_size(data),
         true <- size >= 1 do
      piece_size = min(piece_length, total - index * piece_length)

      if begin >= 0 and begin + size <= piece_size do
        :ok
      else
        {:error, :block_out_of_bounds}
      end
    else
      _ -> {:error, :invalid_block}
    end
  end

  def validate_block(_info, _index, _begin, _data), do: {:error, :invalid_block}

  @doc """
  True when path components stay confined: no parent or self references,
  no absolute components, no empties. Returns the joined relative path.
  """
  def validate_path(parts) when is_list(parts) and parts != [] do
    case Enum.find(parts, &(not valid_component?(&1))) do
      nil -> {:ok, Path.join(parts)}
      bad -> {:error, classify_component(bad)}
    end
  end

  def validate_path(_parts), do: {:error, :empty_path}

  defp valid_component?(component) when is_binary(component) and component != "" do
    component != "." and component != ".." and not String.starts_with?(component, "/")
  end

  defp valid_component?(_component), do: false

  defp classify_component("."), do: :path_escape
  defp classify_component(".."), do: :path_escape
  defp classify_component(""), do: :empty_component
  defp classify_component(component) when is_binary(component), do: :absolute_path
  defp classify_component(_component), do: :invalid_component

  @doc """
  Get the remaining length from a Bento torrent file
  Handles both single file torrents and multi-file torrents
  """
  def remaining(bento_torrent) do
    info_total(bento_torrent.info)
  end

  defp info_total(%{files: files}) when is_list(files) do
    Enum.reduce(files, 0, fn file, acc -> acc + file.length end)
  end

  defp info_total(%{length: length}) when is_integer(length), do: length
  defp info_total(_info), do: 0

  @doc """
  Hex info-hash over the full decoded info map, all keys as found.
  Expects the raw string-keyed map from a validated torrent (`parse_torrent_file`);
  file bytes are the validated hostile input, so this stays total. Structs
  must not be re-encoded here: Bento drops unknown info keys.
  """
  def info_hash(info) when is_map(info) do
    info
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Bento.encode!()
    |> Utils.sha_sum()
    |> Base.encode16()
  end
end
