defmodule TorrentFidelityTest do
  @moduledoc """
  The info-hash is only hash-of-encoded-form-as-found if Bento round-trips
  byte-identically. This locks that assumption per fixture instead of
  assuming it.
  """
  use ExUnit.Case, async: true

  test "every fixture re-encodes byte-identically" do
    for path <- Path.wildcard("test/_data/*.torrent") do
      {:ok, bytes} = File.read(path)
      {:ok, decoded} = Bento.decode(bytes)

      assert Bento.encode!(decoded) == bytes, "round-trip drift in #{path}"
    end
  end

  test "info_hash ignores nil-valued absent keys" do
    {:ok, _bento, info} =
      Downloader.parse_torrent_file("test/_data/debian-12.1.0-amd64-netinst.iso.torrent")

    assert Torrent.info_hash(Map.put(info, "source", nil)) == Torrent.info_hash(info)
  end

  test "info_hash equals the hash of the as-found info dict" do
    for path <- Path.wildcard("test/_data/*.torrent") do
      {:ok, _bento, info} = Downloader.parse_torrent_file(path)
      {:ok, bytes} = File.read(path)
      {:ok, raw} = RawBencode.info_bytes(bytes)

      assert Torrent.info_hash(info) == Base.encode16(:crypto.hash(:sha, raw)),
             "info_hash drift in #{path}"
    end
  end
end
