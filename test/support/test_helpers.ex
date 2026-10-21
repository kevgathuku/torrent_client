defmodule TestHelpers do
  @moduledoc """
  Test-only fixture paths. Lives in test/support so production code
  can't reach for test data.
  """

  def single_file_torrent do
    "test/_data/debian-12.1.0-amd64-netinst.iso.torrent"
  end

  def multi_file_torrent do
    "test/_data/big-buck-bunny.torrent"
  end

  # Read a .torrent file and parse it: file errors pass through, so
  # missing-file tests keep asserting on the tuple.
  def parse_torrent(path) do
    with {:ok, bytes} <- File.read(path) do
      Torrent.parse_bytes(bytes)
    end
  end
end
