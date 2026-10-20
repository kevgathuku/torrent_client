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
end
