defmodule TorrentClientTest do
  use ExUnit.Case
  doctest TorrentClient

  test "greets the world" do
    assert TorrentClient.hello() == :world
  end
end
