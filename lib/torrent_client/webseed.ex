defmodule TorrentClient.Webseed do
  @moduledoc """
  BEP-19 webseed fetching: build per-file URLs from `url-list` bases and
  pull missing pieces over HTTP Range requests.

  URL shape follows the spec: a base ending in `/` is a directory and the
  torrent name (plus the file path for multi-file torrents) is appended;
  anything else is a complete single-file URL used verbatim. Only
  `http(s)` bases are dialed; unknown schemes (notably `ftp`, which needs
  a different resume mechanism) are skipped, never failed.

  `fetch_piece/4` maps the piece through `Torrent.piece_span/2` and
  `Torrent.split_span/3`, so a piece straddling files becomes one Range
  GET per file slice, concatenated in torrent order. Bases are tried in
  order per slice; the first good body wins. A `206` must carry exactly
  the slice; a `200` (Range ignored) must at least cover the slice
  window, which is then cut out locally.
  """

  @doc """
  File URL for one layout entry under `base`, or `:error` when the base
  cannot address this torrent (a non-directory base with a multi-file
  torrent). `rel_path` is the layout-relative path (`name` on its own
  for single-file torrents).
  """
  def file_url(base, info, rel_path)
      when is_binary(base) and is_map(info) and is_binary(rel_path) do
    if String.ends_with?(base, "/") do
      {:ok, base <> encode_path(rel_path)}
    else
      if multi_file?(info), do: :error, else: {:ok, base}
    end
  end

  def file_url(_, _, _), do: :error

  @doc """
  Fetch piece `index` through `http` (a `WebseedHttpBehaviour` impl),
  trying every base URL in order. Returns the raw piece bytes; hashing
  and writing stay with the caller, mirroring the peer path.
  """
  def fetch_piece(http, urls, info, index)
      when is_atom(http) and is_list(urls) and is_map(info) and is_integer(index) do
    with {:ok, {offset, size}} <- Torrent.piece_span(info, index),
         {:ok, entries} <- Torrent.layout(info) do
      slices = Torrent.split_span(entries, offset, size)

      fetch_slices(http, sane_bases(urls), info, slices, [])
    end
  end

  def fetch_piece(_, _, _, _), do: {:error, :invalid_piece}

  # -- slices ------------------------------------------------------------------

  defp fetch_slices(_http, _urls, _info, [], acc),
    do: {:ok, acc |> Enum.reverse() |> Enum.join("")}

  defp fetch_slices(http, urls, info, [{rel, file_offset, length} | rest], acc) do
    case fetch_slice(http, urls, info, rel, file_offset, length) do
      {:ok, data} -> fetch_slices(http, urls, info, rest, [data | acc])
      {:error, _} = err -> err
    end
  end

  defp fetch_slice(http, urls, info, rel, file_offset, length) do
    range = "bytes=#{file_offset}-#{file_offset + length - 1}"

    Enum.find_value(urls, {:error, :webseed_failed}, fn base ->
      with {:ok, url} <- file_url(base, info, rel),
           {:ok, %{status: status, body: body}} <- safe_get(http, url, range),
           {:ok, data} <- slice_body(status, body, file_offset, length) do
        {:ok, data}
      else
        _ -> nil
      end
    end)
  end

  defp safe_get(http, url, range) do
    http.get(url, [{"range", range}])
  rescue
    _ -> {:error, :webseed_crashed}
  catch
    _, _ -> {:error, :webseed_crashed}
  end

  defp slice_body(206, body, _offset, length) when is_binary(body) do
    if byte_size(body) == length, do: {:ok, body}, else: {:error, :short_body}
  end

  defp slice_body(200, body, offset, length) when is_binary(body) do
    if byte_size(body) >= offset + length,
      do: {:ok, binary_part(body, offset, length)},
      else: {:error, :short_body}
  end

  defp slice_body(_status, _body, _offset, _length), do: {:error, :bad_status}

  # -- helpers -----------------------------------------------------------------

  defp sane_bases(urls) do
    Enum.filter(urls, fn url -> URI.parse(url).scheme in ["http", "https"] end)
  rescue
    _ -> []
  end

  defp multi_file?(%{files: files}) when is_list(files), do: true
  defp multi_file?(%{"files" => files}) when is_list(files), do: true
  defp multi_file?(_), do: false

  defp encode_path(rel) do
    rel
    |> String.split("/")
    |> Enum.map_join("/", fn part -> URI.encode(part, &URI.char_unreserved?/1) end)
  end
end
