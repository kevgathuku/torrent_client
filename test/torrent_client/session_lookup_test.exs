defmodule TorrentClient.SessionLookupTest do
  @moduledoc """
  Addressing over a torrents map: exact hex id, unique prefix, path
  fallback — all without a running session.
  """

  use ExUnit.Case, async: true

  alias TorrentClient.SessionLookup

  defp entry(raw, path), do: %{raw: raw, id: Base.encode16(raw), path: path}

  setup do
    # Fixed first bytes: ids start "01…" and "02…", so "0" is ambiguous
    # and "01" is unique, deterministically.
    a = entry(<<1>> <> :binary.copy(<<0>>, 19), "a.torrent")
    b = entry(<<2>> <> :binary.copy(<<0>>, 19), "b.torrent")

    %{a: a, b: b, torrents: %{a.raw => a, b.raw => b}}
  end

  test "exact hex id resolves", %{torrents: torrents, a: a} do
    assert {:ok, raw, ^a} = SessionLookup.find(torrents, a.id)
    assert raw == a.raw
  end

  test "a unique id prefix resolves", %{torrents: torrents, a: a} do
    assert {:ok, raw, ^a} = SessionLookup.find(torrents, "01")
    assert raw == a.raw
  end

  test "an ambiguous prefix fails closed", %{torrents: torrents} do
    assert {:error, :not_found} = SessionLookup.find(torrents, "0")
  end

  test "torrent path is the fallback", %{torrents: torrents, b: b} do
    assert {:ok, raw, ^b} = SessionLookup.find(torrents, "b.torrent")
    assert raw == b.raw
  end

  test "unknown id, unknown path, and empty table fail closed", %{a: a} do
    torrents = %{a.raw => a}
    assert {:error, :not_found} = SessionLookup.find(torrents, "ZZZ-not-an-id")
    assert {:error, :not_found} = SessionLookup.find(torrents, "missing.torrent")
    assert {:error, :not_found} = SessionLookup.find(%{}, a.id)
  end

  test "non-binary input fails closed", %{torrents: torrents} do
    assert {:error, :not_found} = SessionLookup.find(torrents, :atom)
    assert {:error, :not_found} = SessionLookup.find(torrents, 123)
    assert {:error, :not_found} = SessionLookup.find(torrents, nil)
  end
end
