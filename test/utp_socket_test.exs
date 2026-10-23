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

    assert {:error, :timeout} =
             TorrentClient.UtpNetwork.connect(%Peer{
               ip_tuple: {127, 0, 0, 1},
               port: port
             })
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

  test "a timed-out recv consumes nothing" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    # Nothing arrives: the recv times out and must leave no waiter
    # behind to eat later bytes (SocketBehaviour: timeouts consume
    # nothing, like :gen_tcp.recv/3).
    assert {:error, :timeout} = UtpSocket.recv(pid, 10, 200)
    assert :sys.get_state(pid).waiters == []
    assert {:error, :timeout} = UtpSocket.recv(pid, 10, 0)
    assert :sys.get_state(pid).waiters == []

    send(peer, {:send_bytes, "hello-dire"})
    assert {:ok, "hello-dire"} = UtpSocket.recv(pid, 10, 3_000)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "retires acks piggybacked on DATA" do
    parent = self()
    {peer, port} = UtpPeer.start(parent, %{auto_ack: false})
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    :ok = UtpSocket.send(pid, "ping")
    assert_receive {:peer_data, 2, "ping"}, 2_000
    # The only acknowledgment of seq 2 rides on the reply DATA.
    send(peer, {:send_bytes, "pong"})
    assert {:ok, "pong"} = UtpSocket.recv(pid, 4, 3_000)
    assert_eventually(fn -> :sys.get_state(pid).send_buf == [] end)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "ignores stale and ahead acks instead of retiring the send buffer" do
    parent = self()
    {peer, port} = UtpPeer.start(parent, %{auto_ack: false})
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    # Two requests in flight, both retired by the ack on the reply DATA.
    :ok = UtpSocket.send(pid, "aa")
    :ok = UtpSocket.send(pid, "bb")
    assert_receive {:peer_data, 2, "aa"}, 2_000
    assert_receive {:peer_data, 3, "bb"}, 2_000
    send(peer, {:send_bytes, "x"})
    assert {:ok, "x"} = UtpSocket.recv(pid, 1, 3_000)
    assert_eventually(fn -> :sys.get_state(pid).send_buf == [] end)
    assert :sys.get_state(pid).last_ack_nr == 3

    # A third request goes out; only forged STATEs follow.
    :ok = UtpSocket.send(pid, "cc")
    assert_receive {:peer_data, 4, "cc"}, 2_000

    # Stale ack (behind last_ack_nr): retires nothing, moves nothing.
    send(peer, {:forge_state, 2})
    Process.sleep(300)
    state = :sys.get_state(pid)
    assert length(state.send_buf) == 1
    assert state.last_ack_nr == 3

    # Ahead ack (past everything sent): same, nothing retired.
    send(peer, {:forge_state, 9})
    Process.sleep(300)
    state = :sys.get_state(pid)
    assert length(state.send_buf) == 1
    assert state.last_ack_nr == 3

    # The connection still converges on the real ack.
    send(peer, {:send_bytes, "y"})
    assert {:ok, "y"} = UtpSocket.recv(pid, 1, 3_000)
    assert_eventually(fn -> :sys.get_state(pid).send_buf == [] end)
    assert :sys.get_state(pid).last_ack_nr == 4
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "buffers gaps, SACKs them, and completes on FIN" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000

    # In-order byte, then a hole, a future byte, an early FIN, and a
    # duplicate of the first byte — all out of the normal send path.
    send(peer, {:send_bytes, "a"})
    assert {:ok, "a"} = UtpSocket.recv(pid, 1, 3_000)
    ack = :sys.get_state(pid).ack_nr
    send(peer, {:skip_seq})
    send(peer, {:send_bytes, "b"})
    assert_receive {:peer_ack, ^ack, [_ | _]}, 3_000
    send(peer, {:send_fin})
    send(peer, {:send_fin})
    send(peer, {:send_at_seq, ack, "a"})
    send(peer, {:send_at_seq, ack + 1 &&& 0xFFFF, "H"})
    assert {:ok, "H"} = UtpSocket.recv(pid, 1, 3_000)
    assert {:ok, "b"} = UtpSocket.recv(pid, 1, 3_000)
    assert {:error, :closed} = UtpSocket.recv(pid, 1, 3_000)
    :ok = UtpSocket.close(pid)
    send(peer, {:close})
  end

  test "drops far-ahead packets without buffering" do
    parent = self()
    {peer, port} = UtpPeer.start(parent)
    {:ok, pid} = UtpSocket.connect({127, 0, 0, 1}, port, [])
    assert_receive {:peer_syn, _conn, 1}, 2_000
    ack = :sys.get_state(pid).ack_nr
    # A hostile 1000-packet jump: never buffered, never SACKed raw.
    send(peer, {:send_at_seq, ack + 1_000 &&& 0xFFFF, "x"})
    Process.sleep(200)
    assert :sys.get_state(pid).recv_buf == %{}
    # ...and the stream still works afterwards.
    send(peer, {:send_bytes, "ok"})
    assert {:ok, "ok"} = UtpSocket.recv(pid, 2, 3_000)
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

    # Establish a real baseline first: the first nonzero sample sets
    # the base, so a lone forged sample would baseline itself.
    send(peer, {:send_bytes, "w"})
    assert {:ok, "w"} = UtpSocket.recv(pid, 1, 3_000)
    # Keep 1_400 bytes in flight (peer never ACKs), then report a
    # 500 ms buffering delay: the window must hit the floor. The forge
    # goes out only after our bytes landed — every inbound packet
    # re-measures the peer's clock, which would overwrite it.
    send(peer, {:ignore_acks, 99})
    :ok = UtpSocket.send(pid, :binary.copy(<<1>>, 1_400))
    assert_receive {:peer_data, 2, _}, 3_000
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
