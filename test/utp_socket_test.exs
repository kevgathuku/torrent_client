defmodule UtpSocketTest do
  @moduledoc """
  `UtpSocket` against a scripted raw-UDP peer: handshake, ordered
  exchange, timeout retransmit, SACK fast resend, FIN/RST close, and the
  LEDBAT direction. The peer is deliberately dumb (no timers of its
  own) so every loss and reorder is programmed, never raced: drops and
  ignores are configured at start, before any byte can arrive.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias TorrentClient.{Utp, UtpSocket}

  # -- scripted peer --------------------------------------------------------

  # -- tests ----------------------------------------------------------------

  # Loopback UDP and Erlang messages race: poll state until it settles
  # instead of asserting the instant a peer report lands.
  defp assert_eventually(fun, deadline \\ 3_000) do
    stop = System.monotonic_time(:millisecond) + deadline
    poll(fun, stop)
  end

  defp poll(fun, stop) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) > stop do
        flunk("condition never settled")
      else
        Process.sleep(20)
        poll(fun, stop)
      end
    end
  end

  test "connect performs the SYN handshake" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, conn, 1}, 2_000
    state = :sys.get_state(pid)
    assert state.recv_id == conn
    assert state.send_id == (conn + 1 &&& 0xFFFF)
    assert state.status == :connected
    assert state.seq_next == 2
    assert state.last_ack_nr == 1
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "connect fails closed with no responder" do
    {:ok, udp} = :gen_udp.open(0, [:binary])
    {:ok, port} = :inet.port(udp)
    :gen_udp.close(udp)
    assert {:error, :timeout} = UtpSocket.connect({127, 0, 0, 1}, port, connect_timeout: 300)
  end

  test "exchanges ordered bytes both ways" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    :ok = UtpSocket.send(pid, :binary.copy(<<7>>, 3_000))
    expected = :binary.copy(<<7>>, 3_000)
    # Reassembly reports are cumulative; pin the complete one.
    assert_receive {:peer_reassembled, ^expected}, 3_000

    # Three DATA packets consumed sequences 2, 3, 4 and all got acked.
    state = :sys.get_state(pid)
    assert state.seq_next == 5
    assert_eventually(fn -> :sys.get_state(pid).send_buf == [] end)

    send(peer, {:send_bytes, :binary.copy(<<9>>, 100)})
    assert {:ok, result} = UtpSocket.recv(pid, 100, 3_000)
    assert result == :binary.copy(<<9>>, 100)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "retransmits unacked data after timeout" do
    parent = self()
    {peer, port} = UtpPeer.start(parent, %{ignore_acks: 1})
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    :ok = UtpSocket.send(pid, <<1, 2, 3>>)
    assert_receive {:peer_ignored, 2}, 2_000
    # Silence through the 1 s initial timeout, then the retry lands.
    assert_receive {:peer_data, 2, <<1, 2, 3>>}, 4_000
    assert_eventually(fn -> :sys.get_state(pid).send_buf == [] end)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "fast-resends three sacks past the oldest" do
    parent = self()
    # Drop the fourth DATA packet (seq 5); the rest arrive and SACK past it.
    {peer, port} = UtpPeer.start(parent, %{drop_rx: [5]})
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    # Seven small packets go out at once (700 bytes < initial window).
    for _ <- 1..7, do: :ok = UtpSocket.send(pid, <<0::800>>)
    assert_receive {:peer_dropped, 5}, 3_000
    # Three SACKs past seq 5 trigger the fast resend, no timeout wait.
    assert_receive {:peer_data, 5, _}, 3_000
    assert_eventually(fn -> :sys.get_state(pid).send_buf == [] end)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "close sends FIN and a peer FIN closes recv" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000
    :ok = UtpSocket.close(pid)
    assert_receive {:peer_fin, _seq}, 2_000

    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000
    send(peer, {:send_bytes, "hi"})
    send(peer, {:send_fin})
    assert {:ok, "hi"} = UtpSocket.recv(pid, 2, 3_000)
    assert {:error, :closed} = UtpSocket.recv(pid, 1, 3_000)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "reset fails closed" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000
    send(peer, {:send_rst})
    assert {:error, :closed} = UtpSocket.recv(pid, 1, 3_000)
    assert {:error, :closed} = UtpSocket.send(pid, "x")
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "ledbat shrinks the window under delay and grows it back" do
    parent = self()
    {peer, port} = UtpPeer.start(parent, %{ignore_acks: 99})
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000
    assert :sys.get_state(pid).max_window == 1_400

    # Keep 1_400 bytes in flight (peer never ACKs), then report a
    # 500 ms buffering delay: the window must hit the floor.
    :ok = UtpSocket.send(pid, :binary.copy(<<1>>, 1_400))
    send(peer, {:ts_diff, 500_000})
    send(peer, {:send_bytes, "x"})
    assert {:ok, "x"} = UtpSocket.recv(pid, 1, 3_000)
    assert :sys.get_state(pid).max_window == 150

    # Idle link again: the window recovers. Exact samples are loopback
    # jitter, so only the direction is asserted (the math is exact in
    # the unit tests).
    send(peer, {:ts_diff, 10})
    send(peer, {:send_bytes, "y"})
    assert {:ok, "y"} = UtpSocket.recv(pid, 1, 3_000)
    assert :sys.get_state(pid).max_window > 150
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end
end
