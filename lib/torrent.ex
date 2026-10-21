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

    for i <- 0..(num_hashes - 1), do: binary_part(pieces, i * @hash_length, @hash_length)
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

  @doc """
  Ordered file entries for the torrent's info dict, each with its relative
  path and global byte offset. Single-file info yields one entry; multi-file
  info yields one per file under the torrent name dir (BEP-3 concatenation
  order). Every path is validated up front, so hostile entries fail before
  any caller runs mkdir.
  """
  @spec layout(map()) :: {:ok, [map()]} | {:error, term()}
  def layout(info) when is_map(info) do
    case Map.get(info, :"piece length") do
      plen when is_integer(plen) and plen > 0 -> layout_entries(info)
      _ -> {:error, :invalid_piece_length}
    end
  end

  def layout(_info), do: {:error, :invalid_info}

  @doc """
  Global byte span of a piece as `{offset, size}`. The last piece may be
  short; unknown indices fail instead of addressing outside the torrent.
  """
  @spec piece_span(map(), integer()) ::
          {:ok, {non_neg_integer(), pos_integer()}} | {:error, term()}
  def piece_span(info, index) when is_map(info) and is_integer(index) and index >= 0 do
    with {:ok, entries} <- layout(info) do
      plen = Map.get(info, :"piece length")
      total = Enum.reduce(entries, 0, &(&1.length + &2))

      if index < div(total + plen - 1, plen) do
        {:ok, {index * plen, min(plen, total - index * plen)}}
      else
        {:error, :piece_out_of_bounds}
      end
    end
  end

  def piece_span(_info, _index), do: {:error, :invalid_piece}

  @doc """
  Split a global `{offset, size}` span into per-file slices as
  `{path, file_offset, length}` tuples, in torrent order. Zero-length files
  never overlap, so they drop out naturally.
  """
  @spec split_span([map()], non_neg_integer(), pos_integer()) :: [
          {String.t(), non_neg_integer(), pos_integer()}
        ]
  def split_span(entries, offset, size) do
    stop = offset + size

    for entry <- entries,
        first = max(offset, entry.offset),
        last = min(stop, entry.offset + entry.length),
        first < last do
      {entry.path, first - entry.offset, last - first}
    end
  end

  defp valid_component?(component) when is_binary(component) and component != "" do
    component != "." and component != ".." and not String.starts_with?(component, "/")
  end

  defp valid_component?(_component), do: false

  defp classify_component("."), do: :path_escape
  defp classify_component(".."), do: :path_escape
  defp classify_component(""), do: :empty_component
  defp classify_component(component) when is_binary(component), do: :absolute_path
  defp classify_component(_component), do: :invalid_component

  defp layout_entries(%{files: files} = info) when is_list(files) do
    with {:ok, name} <- layout_name(info) do
      append_files(files, name, 0, [])
    end
  end

  defp layout_entries(%{length: length} = info) when is_integer(length) and length >= 0 do
    with {:ok, name} <- layout_name(info),
         {:ok, rel} <- validate_path([name]) do
      {:ok, [%{path: rel, length: length, offset: 0}]}
    end
  end

  defp layout_entries(_info), do: {:error, :unknown_layout}

  defp layout_name(%{name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp layout_name(_info), do: {:error, :missing_name}

  defp append_files([], _name, _offset, []), do: {:error, :no_files}
  defp append_files([], _name, _offset, acc), do: {:ok, Enum.reverse(acc)}

  defp append_files([file | rest], name, offset, acc) do
    with {:ok, rel} <- file_rel(name, file),
         {:ok, length} <- file_length(file) do
      append_files(rest, name, offset + length, [
        %{path: rel, length: length, offset: offset} | acc
      ])
    end
  end

  defp file_rel(name, %{path: parts}) when is_list(parts), do: validate_path([name | parts])
  defp file_rel(_name, _file), do: {:error, :invalid_file_path}

  defp file_length(%{length: length}) when is_integer(length) and length >= 0, do: {:ok, length}
  defp file_length(_file), do: {:error, :invalid_file_length}

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
  Parse `.torrent` bytes. Returns the bento struct alongside the raw
  string-keyed info map, which is what `info_hash/1` must hash (structs
  drop unknown info keys, so the struct alone cannot reproduce the hash).
  Stays pure: callers read the file (the session through its disk seam).
  """
  @spec parse_bytes(binary()) :: {:ok, struct(), map()} | {:error, term()}
  def parse_bytes(contents) when is_binary(contents) do
    # Double parse of a few KB: structs drop unknown info keys, so the raw
    # string-keyed map comes from a plain decode for hashing.
    with {:ok, parsed_torrent} <- Bento.torrent(contents),
         {:ok, decoded} <- Bento.decode(contents) do
      case decoded do
        %{"info" => info} when is_map(info) -> {:ok, parsed_torrent, info}
        _ -> {:error, :missing_info}
      end
    end
  end

  def parse_bytes(_contents), do: {:error, :invalid_torrent}

  @doc """
  Hex info-hash over the full decoded info map, all keys as found.
  Expects the raw string-keyed map from a validated torrent (`parse_bytes/1`);
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
