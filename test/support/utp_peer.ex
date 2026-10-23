defmodule UtpPeer do
  @moduledoc """
  Test-only scripted uTP peer: responder side of the handshake, then a
  programmable DATA plane over raw UDP. Auto-ACKs in-order bytes,
  buffers gaps with SACK, drops or ignores on instruction, forges the
  reported delay, and reports everything to the owning test. Shared by
  the socket and peer-worker uTP tests so neither duplicates it.
  """

  alias TorrentClient.Utp

  import Bitwise

  def start(test, opts \\ %{}) do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: true])
    {:ok, port} = :inet.port(udp)

    base = %{
      udp: udp,
      test: test,
      state: :idle,
      ignore_acks: Map.get(opts, :ignore_acks, 0),
      drop_rx: MapSet.new(Map.get(opts, :drop_rx, []))
    }

    pid = spawn_link(fn -> loop(base) end)
    :gen_udp.controlling_process(udp, pid)
    {pid, port}
  end

  defp loop(st) do
    receive do
      {:udp, udp, ip, port, data} ->
        loop(incoming(%{st | udp: udp}, ip, port, data))

      {:ignore_acks, n} ->
        loop(%{st | ignore_acks: n})

      {:ts_diff, value} ->
        # Forge the delay the peer reports: exercises our LEDBAT
        # reaction to congested vs idle links, deterministically.
        loop(%{st | reply_micro: value})

      {:drop_rx, seqs} ->
        loop(%{st | drop_rx: MapSet.new(seqs)})

      {:send_bytes, bytes} ->
        loop(peer_send(%{st | send_queue: st.send_queue ++ [bytes]}))

      {:send_fin} ->
        loop(peer_fin(st))

      {:send_rst} ->
        send_raw(st, :reset, <<>>, st.seq_next)
        loop(st)

      {:close} ->
        :gen_udp.close(st.udp)
    end
  end

  defp ready(ip, port, test, udp, st) do
    %{
      udp: udp,
      test: test,
      state: :ready,
      peer: {ip, port},
      recv_id: nil,
      send_id: nil,
      ack_nr: 0,
      seq_next: :rand.uniform(0x10000) - 1,
      pending: %{},
      app: <<>>,
      ignore_acks: st.ignore_acks,
      drop_rx: st.drop_rx,
      send_queue: [],
      reply_ts: nil,
      reply_micro: 0,
      eof: false
    }
  end

  defp incoming(st, ip, port, data) do
    case Utp.decode(data) do
      {:ok, %{type: :syn} = header, _payload} ->
        # A fresh SYN (re)initializes the session, so reconnects work.
        accept_syn(st, ip, port, header)

      {:ok, header, payload} ->
        if {ip, port} == peer_of(st) and header.conn_id == st.recv_id do
          st |> note_ts(header) |> handle(header, payload)
        else
          st
        end

      {:error, _} ->
        st
    end
  end

  defp peer_of(%{state: :idle}), do: :none
  defp peer_of(st), do: st.peer

  defp accept_syn(st, ip, port, header) do
    send(st.test, {:peer_syn, header.conn_id, header.seq})
    st = ready(ip, port, st.test, st.udp, st)

    st = %{
      st
      | recv_id: header.conn_id + 1 &&& 0xFFFF,
        send_id: header.conn_id,
        ack_nr: header.seq
    }

    send_raw(st, :state, <<>>, st.seq_next)
    %{st | state: :ready}
  end

  defp handle(st, %{type: :data, seq: seq}, payload) do
    send(st.test, {:peer_data, seq, payload})

    cond do
      MapSet.member?(st.drop_rx, seq) ->
        # One-shot: the retry must land, or nothing can recover.
        send(st.test, {:peer_dropped, seq})
        %{st | drop_rx: MapSet.delete(st.drop_rx, seq)}

      st.ignore_acks > 0 ->
        send(st.test, {:peer_ignored, seq})
        %{st | ignore_acks: st.ignore_acks - 1}

      seq == (st.ack_nr + 1 &&& 0xFFFF) ->
        send(st.test, {:peer_bytes, payload})
        st = %{st | app: st.app <> payload, ack_nr: seq}
        st = drain(st)
        send(st.test, {:peer_reassembled, st.app})
        ack(st)

      Map.has_key?(st.pending, seq) or seq == st.ack_nr or Utp.seq_lt(seq, st.ack_nr) ->
        ack(st)

      true ->
        ack(%{st | pending: Map.put(st.pending, seq, payload)})
    end
  end

  defp handle(st, %{type: :state, ack: ack, sack: sack}, _payload) do
    send(st.test, {:peer_ack, ack, sack})
    st
  end

  defp handle(st, %{type: :fin, seq: seq}, _payload) do
    send(st.test, {:peer_fin, seq})
    %{st | eof: true}
  end

  defp handle(st, %{type: :reset}, _payload) do
    send(st.test, :peer_reset)
    st
  end

  defp handle(st, %{type: :syn}, _payload), do: st

  defp drain(st) do
    next = st.ack_nr + 1 &&& 0xFFFF

    case Map.pop(st.pending, next) do
      {nil, _} ->
        st

      {payload, rest} ->
        send(st.test, {:peer_bytes, payload})
        drain(%{st | app: st.app <> payload, ack_nr: next, pending: rest})
    end
  end

  defp ack(st) do
    sack = if map_size(st.pending) > 0, do: MapSet.new(Map.keys(st.pending)), else: nil
    send_raw(st, :state, <<>>, st.seq_next, sack)
    st
  end

  defp peer_send(%{send_queue: []} = st), do: st

  defp peer_send(st) do
    [head | tail] = st.send_queue

    {chunk, rest} =
      if byte_size(head) > 1_400,
        do: {binary_part(head, 0, 1_400), binary_part(head, 1_400, byte_size(head) - 1_400)},
        else: {head, <<>>}

    queue = if rest == <<>>, do: tail, else: [rest | tail]
    send_raw(st, :data, chunk, st.seq_next)
    peer_send(%{st | send_queue: queue, seq_next: st.seq_next + 1 &&& 0xFFFF})
  end

  defp peer_fin(st) do
    send_raw(st, :fin, <<>>, st.seq_next)
    %{st | seq_next: st.seq_next + 1 &&& 0xFFFF}
  end

  defp note_ts(st, header) do
    now = System.monotonic_time(:microsecond)
    %{st | reply_ts: header.ts, reply_micro: now - header.ts &&& 0xFFFFFFFF}
  end

  defp send_raw(st, type, payload, seq, sack \\ nil) do
    opts = if sack == nil, do: [], else: [sack: sack]

    header = %{
      type: type,
      conn_id: st.send_id,
      ts: System.monotonic_time(:microsecond) &&& 0xFFFFFFFF,
      ts_diff: st.reply_micro,
      wnd: 262_144,
      seq: seq,
      ack: st.ack_nr
    }

    {ip, port} = st.peer
    :gen_udp.send(st.udp, ip, port, Utp.encode(header, opts) <> payload)
  end
end
