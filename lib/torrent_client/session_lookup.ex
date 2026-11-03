defmodule TorrentClient.SessionLookup do
  @moduledoc """
  Pure torrent addressing over the session's torrents map.

  One torrent is found by exact hex id first, unique id prefix second,
  torrent path third. Registry keys are raw bytes, so callers never hit
  an exact-key match — a full id is its own unique prefix, which
  subsumes it. Unknown ids, ambiguous prefixes, and non-binary search
  terms read as `{:error, :not_found}`. Entries are session entries
  carrying `:raw` and `:path`.
  """

  @doc """
  Find one entry in `torrents` (`%{raw_info_hash => entry}`).

  Returns `{:ok, raw, entry}` or `{:error, :not_found}`.
  """
  @spec find(%{binary() => map()}, term()) :: {:ok, binary(), map()} | {:error, :not_found}
  def find(torrents, id_or_path) do
    cond do
      matching = prefix_match(torrents, id_or_path) ->
        {:ok, matching.raw, matching}

      matching = path_match(torrents, id_or_path) ->
        {:ok, matching.raw, matching}

      true ->
        {:error, :not_found}
    end
  end

  defp prefix_match(torrents, prefix) when is_binary(prefix) do
    case Enum.filter(torrents, fn {raw, _} -> String.starts_with?(hex(raw), prefix) end) do
      [{_raw, entry}] -> entry
      _ -> nil
    end
  end

  defp prefix_match(_torrents, _prefix), do: nil

  defp path_match(torrents, path) do
    case Enum.filter(torrents, fn {_raw, entry} -> entry.path == path end) do
      [{_raw, entry}] -> entry
      _ -> nil
    end
  end

  defp hex(raw), do: Base.encode16(raw)
end
