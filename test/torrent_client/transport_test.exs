defmodule TorrentClient.TransportTest do
  @moduledoc """
  The transport table: one pairing per name, shared by the coordinator
  and the peer workers.
  """

  use ExUnit.Case, async: true

  alias TorrentClient.{GenTcpSocket, Network, Transport, UtpNetwork, UtpSocket}

  test "tcp resolves to the TCP pair" do
    assert Transport.pair(:tcp) == {Network, GenTcpSocket}
  end

  test "utp resolves to the uTP pair" do
    assert Transport.pair(:utp) == {UtpNetwork, UtpSocket}
  end
end
