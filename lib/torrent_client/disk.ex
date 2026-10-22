defmodule TorrentClient.Disk do
  @moduledoc """
  Real disk implementation. Effectful by design — everything in here stays
  out of the domain layer.

  Piece math (layout, spans) lives in `Torrent`; this module only moves
  bytes. `Torrent.layout/1` validates every path before the first mkdir,
  so hostile torrents fail before anything is created. Resume encode/decode
  and `id_from_path/1` live here so the persistence seam owns one filename
  scheme and one error story.
  """

  @behaviour TorrentClient.DiskBehaviour

  require Logger

  @resume_version 1
  @hex_tag "$hex"

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def write(path, data), do: File.write(path, data)

  @impl true
  def rename(from, to), do: File.rename(from, to)

  @impl true
  def delete(path), do: File.rm(path)

  @doc "Resume file for a download dir (dotfile, colocated per torrent)."
  @spec resume_path(Path.t()) :: Path.t()
  def resume_path(base_dir), do: Path.join(base_dir, ".resume")

  @doc "Human-readable resume id from the torrent filename."
  @spec id_from_path(Path.t()) :: {:ok, String.t()} | {:error, :invalid_path}
  def id_from_path(path) when is_binary(path) do
    case Path.basename(path, ".torrent") do
      "" -> {:error, :invalid_path}
      id -> {:ok, id}
    end
  end

  def id_from_path(_path), do: {:error, :invalid_path}

  @doc """
  Create the download layout: parent dirs plus one file per entry, each
  truncated to its declared size. Existing correct-size files are kept.
  Pre-existing symlinks under the layout are rejected before anything is
  created.
  """
  @spec init_layout(Path.t(), map()) :: :ok | {:error, term()}
  @impl true
  def init_layout(base_dir, info) when is_binary(base_dir) and is_map(info) do
    with {:ok, entries} <- Torrent.layout(info),
         :ok <- reject_symlinks(base_dir, entries) do
      init_entries(base_dir, entries)
    end
  end

  def init_layout(_base_dir, _info), do: {:error, :invalid_args}

  # Fail before any mkdir/write when an existing component of an entry path
  # is a symlink: lexical validation cannot see links planted in the download
  # dir. A concurrent plant still races (confined open needs openat2, which
  # has no OTP binding); this closes the deterministic path.
  defp reject_symlinks(base, entries) do
    entries
    |> Enum.map(&Path.join(base, &1.path))
    |> then(&reject_paths(base, &1))
  end

  defp reject_paths(base, full_paths) do
    Enum.reduce_while(full_paths, :ok, fn full, :ok ->
      if symlinked_below?(base, full) do
        {:halt, {:error, :symlink_escape}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp symlinked_below?(base, full) do
    full
    |> Path.relative_to(base)
    |> Path.split()
    |> Enum.scan(base, &Path.join(&2, &1))
    |> Enum.any?(&symlink?/1)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp refuse_symlink(path) do
    if symlink?(path), do: {:error, :symlink_escape}, else: :ok
  end

  defp init_entries(base_dir, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case ensure_sized(Path.join(base_dir, entry.path), entry.length) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Read a whole piece, gathering spans that cross file boundaries."
  @spec read_piece(Path.t(), map(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  @impl true
  def read_piece(base_dir, info, index) when is_binary(base_dir) and is_map(info) do
    with {:ok, entries} <- Torrent.layout(info),
         {:ok, {offset, size}} <- Torrent.piece_span(info, index) do
      read_slices(base_dir, Torrent.split_span(entries, offset, size), [])
    end
  end

  def read_piece(_base_dir, _info, _index), do: {:error, :invalid_args}

  @doc "Write a whole piece, scattering spans that cross file boundaries."
  @spec write_piece(Path.t(), map(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  @impl true
  def write_piece(base_dir, info, index, data)
      when is_binary(base_dir) and is_map(info) and is_binary(data) do
    with {:ok, entries} <- Torrent.layout(info),
         {:ok, {offset, size}} <- Torrent.piece_span(info, index),
         :ok <- check_piece_size(data, size) do
      write_slices(base_dir, Torrent.split_span(entries, offset, size), data)
    end
  end

  def write_piece(_base_dir, _info, _index, _data), do: {:error, :invalid_args}

  @doc """
  Encode resume state to storable bytes. The info-hash binary becomes a
  self-describing tagged hex map so text-oriented stores decode it back to
  bytes (bare hex strings fail byte-oriented code downstream). Accepts the
  verified set or list; stores a sorted unique list.
  """
  @spec encode_resume(map()) :: {:ok, binary()} | {:error, term()}
  def encode_resume(%{info_hash: hash, verified: verified, total: total, piece_length: plen})
      when is_binary(hash) and byte_size(hash) > 0 and is_integer(total) and total > 0 and
             is_integer(plen) and plen > 0 do
    with {:ok, indices} <- resume_indices(verified) do
      payload = %{
        "v" => @resume_version,
        "info_hash" => %{@hex_tag => Base.encode16(hash)},
        "verified" => indices,
        "total" => total,
        "piece_length" => plen
      }

      {:ok, :erlang.term_to_binary(payload)}
    end
  end

  def encode_resume(_state), do: {:error, :invalid_resume}

  @doc "Decode resume bytes back to state with a byte-oriented info-hash."
  @spec decode_resume(binary()) ::
          {:ok,
           %{
             info_hash: binary(),
             verified: [non_neg_integer()],
             total: pos_integer(),
             piece_length: pos_integer()
           }}
          | {:error, term()}
  def decode_resume(binary) when is_binary(binary) do
    with {:ok, term} <- safe_binary_to_term(binary) do
      decode_payload(term)
    end
  end

  def decode_resume(_binary), do: {:error, :invalid_resume}

  @doc """
  Read the verified indices published at `base_dir`, best effort.

  `identity` carries the torrent's `:info_hash`, `:total` and
  `:piece_length`; resume bytes are hostile input and are trusted only
  when all three match. A missing, unreadable, corrupt or foreign file
  yields `[]`, so a download always starts.
  """
  @spec load_verified(module(), Path.t(), %{
          info_hash: binary(),
          total: pos_integer(),
          piece_length: pos_integer()
        }) :: [non_neg_integer()]
  def load_verified(disk, base_dir, %{info_hash: raw, total: total, piece_length: plen})
      when is_binary(base_dir) and is_binary(raw) do
    path = resume_path(base_dir)

    case disk.read(path) do
      {:error, :enoent} ->
        Logger.debug("no resume at #{path}")
        []

      {:ok, bytes} ->
        case decode_resume(bytes) do
          {:ok, %{info_hash: ^raw, verified: indices, total: ^total, piece_length: ^plen}} ->
            # Range check here: decode only promises non-negative ints,
            # and a full-length list with an out-of-range index would
            # otherwise mark the torrent complete with a piece missing.
            valid = Enum.filter(indices, &(&1 < total))
            Logger.debug("resume at #{path}: #{length(valid)}/#{total} verified")
            valid

          {:ok, _} ->
            Logger.warning("ignoring resume with mismatched identity at #{path}")
            []

          {:error, reason} ->
            Logger.warning("ignoring undecodable resume at #{path}: #{inspect(reason)}")
            []
        end

      {:error, reason} ->
        Logger.warning("ignoring unreadable resume at #{path}: #{inspect(reason)}")
        []
    end
  end

  defp check_piece_size(data, size) do
    if byte_size(data) == size, do: :ok, else: {:error, :piece_size_mismatch}
  end

  defp ensure_sized(path, 0) do
    case mkdir_parent(path) do
      :ok -> File.write(path, "")
      {:error, _} = err -> err
    end
  end

  defp ensure_sized(path, length) when is_integer(length) and length > 0 do
    with :ok <- mkdir_parent(path),
         {:ok, fd} <- :file.open(path, [:read, :write, :binary]) do
      try do
        with {:ok, _} <- :file.position(fd, {:bof, length}) do
          :file.truncate(fd)
        end
      after
        :file.close(fd)
      end
    end
  end

  defp mkdir_parent(path), do: File.mkdir_p(Path.dirname(path))

  defp read_slices(_base, [], acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_slices(base, [{rel, offset, length} | rest], acc) do
    case pread(Path.join(base, rel), offset, length) do
      {:ok, chunk} -> read_slices(base, rest, [chunk | acc])
      {:error, _} = err -> err
    end
  end

  defp pread(path, offset, length) do
    with {:ok, fd} <- :file.open(path, [:read, :binary]) do
      try do
        with {:ok, data} <- pread_chunk(fd, offset, length) do
          check_full(data, length)
        end
      after
        :file.close(fd)
      end
    end
  end

  defp pread_chunk(fd, offset, length) do
    case :file.pread(fd, offset, length) do
      :eof -> {:ok, <<>>}
      other -> other
    end
  end

  defp check_full(data, length) do
    if byte_size(data) == length, do: {:ok, data}, else: {:error, :short_read}
  end

  defp write_slices(_base, [], _data), do: :ok

  defp write_slices(base, [{rel, offset, len} | rest], data) do
    chunk = binary_part(data, 0, len)
    remaining = binary_part(data, len, byte_size(data) - len)
    full = Path.join(base, rel)

    # Re-sweep per slice: a parent dir swapped for a symlink after init is
    # a deterministic plant between two calls, not a concurrent race.
    with :ok <- reject_paths(base, [full]) do
      case pwrite(full, offset, chunk) do
        :ok -> write_slices(base, rest, remaining)
        {:error, _} = err -> err
      end
    end
  end

  defp pwrite(path, offset, chunk) do
    # Stat first: open-for-write would create a missing file, but only
    # init_layout may create files (with declared sizes). The symlink gate
    # keeps a planted link from redirecting the write (same race caveat as
    # reject_symlinks/2).
    with :ok <- refuse_symlink(path),
         {:ok, _stat} <- File.stat(path),
         {:ok, fd} <- :file.open(path, [:read, :write, :binary]) do
      try do
        :file.pwrite(fd, offset, chunk)
      after
        :file.close(fd)
      end
    end
  end

  defp resume_indices(%MapSet{} = set), do: resume_indices(MapSet.to_list(set))

  defp resume_indices(list) when is_list(list) do
    if Enum.all?(list, &(is_integer(&1) and &1 >= 0)) do
      {:ok, list |> Enum.sort() |> Enum.uniq()}
    else
      {:error, :invalid_verified}
    end
  end

  defp resume_indices(_other), do: {:error, :invalid_verified}

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> {:error, :corrupt_resume}
  end

  defp decode_payload(%{
         "v" => 1,
         "info_hash" => %{@hex_tag => hex},
         "verified" => verified,
         "total" => total,
         "piece_length" => plen
       })
       when is_integer(total) and total > 0 and is_integer(plen) and plen > 0 do
    with {:ok, hash} <- unhex(hex),
         {:ok, indices} <- resume_indices(verified) do
      {:ok, %{info_hash: hash, verified: indices, total: total, piece_length: plen}}
    end
  end

  defp decode_payload(_term), do: {:error, :invalid_resume}

  defp unhex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, hash} when byte_size(hash) == 20 -> {:ok, hash}
      _ -> {:error, :invalid_info_hash}
    end
  end

  defp unhex(_hex), do: {:error, :invalid_info_hash}
end
