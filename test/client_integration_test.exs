defmodule ClientIntegrationTest do
  @moduledoc """
  A worker (Client) driven against Mox doubles with zero real I/O.
  Sync + global Mox mode: the double is invoked from the worker process,
  not the test process.
  """
  use ExUnit.Case, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  test "worker shuts down cleanly when the network double refuses" do
    expect(TorrentClient.NetworkMock, :connect, fn _peer -> {:error, "Connection refused"} end)

    # Plain map, not %Peer{}: Client still reads the pre-existing peer.ip field
    # (.8 reunites worker and struct). Shape is incidental to this seam.
    peer = %{ip_tuple: {127, 0, 0, 1}, port: 6881, ip: "127.0.0.1"}

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      Client.start_link(%{info_hash: "hash"}, peer, "peer-id", network: TorrentClient.NetworkMock)

    assert_receive {:EXIT, ^pid, "ERROR: Unable to connect to Peer: 127.0.0.1"}
  end
end
