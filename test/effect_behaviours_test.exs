defmodule EffectBehavioursTest do
  @moduledoc """
  Structural contract: every effect has a behaviour, a real implementation
  declaring it, and a Mox double. Behaviour conformance itself is enforced
  by the compiler (`@behaviour`) and by Mox at `defmock` time.
  """
  use ExUnit.Case, async: true

  test "network behaviour exposes connect/1" do
    assert {:connect, 1} in TorrentClient.NetworkBehaviour.behaviour_info(:callbacks)

    assert TorrentClient.Network.__info__(:attributes)[:behaviour] == [
             TorrentClient.NetworkBehaviour
           ]

    assert TorrentClient.NetworkMock.__info__(:functions)[:connect] == 1
  end

  test "disk behaviour exposes piece storage and resume transport" do
    assert {:read, 1} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert {:write, 2} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert {:init_layout, 2} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert {:read_piece, 3} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert {:write_piece, 4} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert {:rename, 2} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert {:delete, 1} in TorrentClient.DiskBehaviour.behaviour_info(:callbacks)
    assert TorrentClient.Disk.__info__(:attributes)[:behaviour] == [TorrentClient.DiskBehaviour]
    assert TorrentClient.DiskMock.__info__(:functions)[:read] == 1
    assert TorrentClient.DiskMock.__info__(:functions)[:init_layout] == 2
    assert TorrentClient.DiskMock.__info__(:functions)[:read_piece] == 3
    assert TorrentClient.DiskMock.__info__(:functions)[:write_piece] == 4
  end

  test "socket behaviour exposes framed send/recv/close" do
    assert {:send, 2} in TorrentClient.SocketBehaviour.behaviour_info(:callbacks)
    assert {:recv, 3} in TorrentClient.SocketBehaviour.behaviour_info(:callbacks)
    assert {:close, 1} in TorrentClient.SocketBehaviour.behaviour_info(:callbacks)

    assert TorrentClient.GenTcpSocket.__info__(:attributes)[:behaviour] == [
             TorrentClient.SocketBehaviour
           ]
  end

  test "clock behaviour exposes monotonic_ms/0" do
    assert {:monotonic_ms, 0} in TorrentClient.ClockBehaviour.behaviour_info(:callbacks)
    assert TorrentClient.Clock.__info__(:attributes)[:behaviour] == [TorrentClient.ClockBehaviour]
    assert TorrentClient.ClockMock.__info__(:functions)[:monotonic_ms] == 0
  end
end
