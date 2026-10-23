defmodule TorrentClient.UtpSocket do
  @moduledoc """
  uTP (BEP-29) connection: a reliable ordered byte stream over UDP, owned
  one per France process. Implements `SocketBehaviour` over a pid, so
  `PeerWorker` drives it through the same `:sock` seam as TCP.

  Initiator role only: `connect/3` runs the SYN handshake, then serves
  `send`/`recv`/`close` calls with retransmission, RTT estimation, and
  LEDBAT congestion control per BEP-29 formulas (pure parts live in
  `TorrentClient.Utp`). One UDP socket per connection; multiplexing and
  the responder (listener) role belong to the NAT-traversal ticket.

  Deliberate shortcuts, all documented at the code: fixed 1400-byte
  payloads (no MTU floor probing — the window floor still throttles to
  one packet on timeout), immediate ACKs (no delayed ACKs), no Nagle
  batching, no RST-on-unknown-connection replies.
  """

  use GenServer

  import Bitwise

  @behaviour TorrentClient.SocketBehaviour

  alias TorrentClient.Utp

  # Fixed payload ceiling: safely under 1500-byte Ethernet MTU after
  # IP + UDP + uTP headers. BEP-29 wants floor probing down to 150 on
  # timeouts; we keep the size and floor the *window* to 150 instead,
  # which throttles to one packet the same way.
  @payload_max 1_400
  @recv_cap 262_144
  @send_queue_cap 1_048_576
  @tick_ms 50
  @max_timeout_ms 60_000
  @default_connect_timeout 5_000

  @typedoc "Owned uTP connection; passed to the `SocketBehaviour` callbacks."
  @type t :: pid()

  @doc """
  Opens a uTP connection to `ip:port`: UDP socket, SYN handshake, first
  SYN-ACK within `:connect_timeout` ms (default #{@default_connect_timeout}).
  Returns the connection pid, which serves the `SocketBehaviour` calls.
  """
  @spec connect(:inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def connect(ip, port, opts \\ []) do
    timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)

    with {:ok, pid} <- GenServer.start_link(__MODULE__, {ip, port}) do
      try do
        case GenServer.call(pid, :await_connected, timeout) do
          :ok -> {:ok, pid}
          {:error, _} = err -> err
        end
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
      end
    end
  end

  @impl true
  @spec send(t(), iodata()) :: :ok | {:error, term()}
  def send(pid, bytes) do
    GenServer.call(pid, {:send, IO.iodata_to_binary(bytes)}, 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :closed}
  end

  @impl true
  @spec recv(t(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv(pid, count, timeout) do
    GenServer.call(pid, {:recv, count}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :closed}
  end

  @impl true
  @spec close(t()) :: :ok | {:error, term()}
  def close(pid) do
    GenServer.call(pid, :close, 5_000)
  catch
    :exit, _ -> :ok
  end

  # -- server ------------------------------------------------------------

  @impl true
  def init({ip, port}) do
    with {:ok, udp} <- :gen_udp.open(0, [:binary, active: true]),
         :ok <- :gen_udp.connect(udp, ip, port) do
      # BEP-29 connection IDs: the SYN carries R, every later send uses
      # R+1, and the return path arrives on R.
      syn_id = :rand.uniform(0x10000) - 1

      state = %{
        udp: udp,
        peer_ip: ip,
        peer_port: port,
        send_id: syn_id + 1 &&& 0xFFFF,
        recv_id: syn_id,
        seq_next: 2,
        ack_nr: 0,
        last_ack_nr: 0,
        dupacks: 0,
        fast_resend_seq: 2,
        send_buf: [],
        send_queue: [],
        queued_bytes: 0,
        recv_buf: %{},
        recv_app: <<>>,
        eof_seq: nil,
        eof_ready: false,
        status: :connecting,
        connect_from: nil,
        connect_deadline: now_ms() + @default_connect_timeout,
        waiters: [],
        reply_ts: nil,
        reply_micro: 0,
        rtt_ms: 0.0,
        rtt_var_ms: 0.0,
        timeout_ms: Utp.initial_timeout_ms(),
        timeouts_consec: 0,
        max_window: @payload_max,
        adv_wnd: @recv_cap,
        base_delay_us: nil,
        base_samples: []
      }

      # SYN consumes sequence 1 and is the one packet sent on the base
      # ID; resends ride the normal timeout path.
      state = record_send(state, :syn, <<>>, 1)
      send_pkt(%{state | send_id: state.recv_id}, :syn, <<>>, 1)
      schedule_tick()

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{udp: udp}) do
    :gen_udp.close(udp)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(:await_connected, _from, %{status: :connected} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_connected, from, state) do
    {:noreply, %{state | connect_from: from}}
  end

  def handle_call({:send, _bytes}, _from, %{status: status} = state)
      when status in [:closed, :fin_sent] do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, bytes}, _from, state) do
    if state.queued_bytes + byte_size(bytes) > @send_queue_cap do
      {:reply, {:error, :send_buffer_full}, state}
    else
      state = %{
        state
        | send_queue: state.send_queue ++ [bytes],
          queued_bytes: state.queued_bytes + byte_size(bytes)
      }

      {:reply, :ok, pump(state)}
    end
  end

  def handle_call({:recv, count}, from, state) do
    cond do
      byte_size(state.recv_app) >= count ->
        <<data::binary-size(^count), rest::binary>> = state.recv_app
        {:reply, {:ok, data}, %{state | recv_app: rest}}

      eof_drained?(state) or state.status == :closed ->
        {:reply, {:error, :closed}, state}

      true ->
        {:noreply, %{state | waiters: state.waiters ++ [{from, count}]}}
    end
  end

  def handle_call(:close, _from, %{status: :closed} = state) do
    cleanup(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:close, _from, %{status: :connecting} = state) do
    # No handshake yet, so no FIN to send: just release the socket.
    cleanup(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:close, _from, state) do
    # Best-effort flush, then FIN consumes the next sequence and the UDP
    # socket dies with the process. The worker closes idle or dying, so
    # nothing valuable is ever stranded here.
    state = pump(state)
    seq = state.seq_next
    send_pkt(state, :fin, <<>>, seq)
    cleanup(state)
    {:stop, :normal, :ok, %{state | status: :fin_sent, seq_next: seq + 1 &&& 0xFFFF}}
  end

  @impl true
  def handle_info({:udp, udp, ip, port, data}, %{udp: udp, peer_ip: ip, peer_port: port} = state) do
    {:noreply, handle_packet(state, data)}
  end

  def handle_info({:udp, _udp, _ip, _port, _data}, state) do
    # Connected socket plus conn_id check below make strays nearly
    # impossible; drop them without a RST (no listener role to defend).
    {:noreply, state}
  end

  # ICMP errors (e.g. refused on a dead peer port) carry no uTP signal:
  # timeouts and resends already cover the loss. Never crash on them.
  def handle_info({:udp_error, _udp, _reason}, state), do: {:noreply, state}
  def handle_info({:udp_closed, _udp}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, on_tick(state)}
  end

  # -- inbound -----------------------------------------------------------

  defp handle_packet(state, data) do
    case Utp.decode(data) do
      {:ok, header, payload} -> handle_packet_decoded(state, header, payload)
      {:error, _} -> state
    end
  end

  defp handle_packet_decoded(state, header, _payload) when header.conn_id != state.recv_id do
    state
  end

  defp handle_packet_decoded(state, %{type: :reset}, _payload) do
    die_closed(state, :reset)
  end

  defp handle_packet_decoded(state, header, payload) do
    state
    |> note_sample(header)
    |> handle_typed(header, payload)
  end

  defp handle_typed(state, %{type: :syn}, _payload), do: state

  defp handle_typed(%{status: :connecting} = state, %{type: :state, ack: 1} = header, _payload) do
    # SYN-ACK: our SYN (seq 1) acknowledged. The SYN-ACK displays their
    # random seq WITHOUT consuming it (libtorrent never increments for
    # STATE), so the baseline sits one below it and their first DATA
    # lands exactly on ack_nr + 1. last_ack_nr stays 0 until ack_out
    # retires the SYN itself — presetting it would orphan the SYN.
    # Duplicate SYN-ACKs later fall into process_ack.
    state = %{state | status: :connected, ack_nr: header.seq - 1 &&& 0xFFFF, adv_wnd: header.wnd}
    state = ack_out(state, 1, header)
    fulfill_connect(state)
  end

  defp handle_typed(%{status: :connecting} = state, _header, _payload), do: state

  defp handle_typed(%{status: closed} = state, _header, _payload)
       when closed in [:closed, :fin_sent] do
    state
  end

  defp handle_typed(state, %{type: :state} = header, _payload) do
    state = %{state | adv_wnd: header.wnd}
    ack_out(state, header.ack, header)
  end

  defp handle_typed(state, %{type: :data, seq: seq} = header, payload) do
    state = %{state | adv_wnd: header.wnd}
    receive_data(state, seq, payload)
  end

  defp handle_typed(state, %{type: :fin, seq: seq} = header, _payload) do
    state = %{state | adv_wnd: header.wnd}
    receive_fin(state, seq)
  end

  # -- acknowledgement ---------------------------------------------------

  defp ack_out(state, ack_nr, header) do
    {newly, rest} = take_acked(state.send_buf, state.last_ack_nr, ack_nr)
    oldest = oldest_seq(state.send_buf)
    state = %{state | send_buf: rest}

    # Cumulative ACKs retire in order; only once-sent packets feed RTT.
    {acked_seqs, state} =
      Enum.map_reduce(newly, state, fn {seq, _payload, _kind, sent_at, sent_count}, acc ->
        acc = if sent_count == 1, do: note_rtt(acc, now_ms() - sent_at), else: acc
        {seq, %{acc | timeouts_consec: 0}}
      end)

    # SACK-acked packets retire the same way (BEP-29 counts both kinds
    # toward RTT).
    {sacked_seqs, state} = Enum.map_reduce(header_sack(header), state, &ack_sacked/2)

    state = fast_resend_past(state, oldest, acked_seqs ++ sacked_seqs)

    if ack_nr != state.last_ack_nr do
      %{state | last_ack_nr: ack_nr, dupacks: 0, fast_resend_seq: ack_nr + 1 &&& 0xFFFF}
      |> pump()
    else
      state = %{state | dupacks: state.dupacks + 1}
      if state.dupacks >= 3, do: fast_resend(state, ack_nr + 1 &&& 0xFFFF), else: state
    end
  end

  defp oldest_seq([]), do: nil
  defp oldest_seq([{seq, _, _, _, _} | _]), do: seq

  # BEP-29 loss rule: 3+ packets acked past the oldest unacked one
  # resends it now instead of waiting out the timeout.
  defp fast_resend_past(state, nil, _acked), do: state

  defp fast_resend_past(state, oldest, acked) do
    past? = fn
      nil -> false
      seq -> seq != oldest and (seq - oldest &&& 0xFFFF) < 0x8000
    end

    if Enum.count(acked, past?) >= 3 and List.keyfind(state.send_buf, oldest, 0) != nil do
      resend(state, oldest)
    else
      state
    end
  end

  # Decoded headers always carry :sack (possibly []) — no fallback.
  defp header_sack(%{sack: sack}), do: sack

  defp take_acked(send_buf, last_ack, ack_nr) do
    window = ack_nr - last_ack &&& 0xFFFF

    Enum.split_with(send_buf, fn {seq, _, _, _, _} ->
      d = seq - last_ack &&& 0xFFFF
      d >= 1 and d <= window
    end)
  end

  defp ack_sacked(seq, state) do
    case List.keytake(state.send_buf, seq, 0) do
      {{_seq, _payload, _kind, sent_at, sent_count}, rest} ->
        state = if sent_count == 1, do: note_rtt(state, now_ms() - sent_at), else: state
        {seq, %{state | send_buf: rest, timeouts_consec: 0}}

      nil ->
        {nil, state}
    end
  end

  defp fast_resend(state, seq) do
    if not Utp.seq_lt(seq, state.fast_resend_seq) and List.keyfind(state.send_buf, seq, 0) != nil do
      state = resend(state, seq)
      %{state | fast_resend_seq: seq + 1 &&& 0xFFFF}
    else
      state
    end
  end

  defp resend(state, seq) do
    case List.keyfind(state.send_buf, seq, 0) do
      {^seq, payload, kind, _sent_at, count} ->
        # SYN resends keep the base ID; everything else uses ID + 1.
        pkt_state = if kind == :syn, do: %{state | send_id: state.recv_id}, else: state
        send_pkt(pkt_state, kind, payload, seq)

        send_buf =
          List.keyreplace(state.send_buf, seq, 0, {seq, payload, kind, now_ms(), count + 1})

        %{state | send_buf: send_buf, max_window: state.max_window * 0.5}

      nil ->
        state
    end
  end

  defp note_rtt(state, sample_ms) do
    {rtt, var} = Utp.rtt_update(state.rtt_ms, state.rtt_var_ms, sample_ms)
    %{state | rtt_ms: rtt, rtt_var_ms: var, timeout_ms: Utp.timeout_for(rtt, var)}
  end

  # -- receive path ------------------------------------------------------

  defp receive_data(state, seq, payload) do
    cond do
      seq == (state.ack_nr + 1 &&& 0xFFFF) ->
        state = %{state | recv_app: state.recv_app <> payload, ack_nr: seq}
        state = drain_recv(state)
        send_ack(state)

      Map.has_key?(state.recv_buf, seq) or seq == state.ack_nr or Utp.seq_lt(seq, state.ack_nr) ->
        send_ack(state)

      map_size(state.recv_buf) < 512 ->
        state = %{state | recv_buf: Map.put(state.recv_buf, seq, payload)}
        send_ack(state)

      true ->
        send_ack(state)
    end
  end

  defp drain_recv(state) do
    next = state.ack_nr + 1 &&& 0xFFFF

    case Map.pop(state.recv_buf, next) do
      {nil, _} ->
        maybe_eof(state) |> fulfill_waiters()

      {payload, rest} ->
        state = %{state | recv_app: state.recv_app <> payload, ack_nr: next, recv_buf: rest}
        drain_recv(state)
    end
  end

  defp receive_fin(state, seq) do
    cond do
      seq == (state.ack_nr + 1 &&& 0xFFFF) ->
        state = %{state | ack_nr: seq, eof_ready: true}
        send_ack(state) |> fulfill_waiters()

      Utp.seq_lt(state.ack_nr, seq) ->
        send_ack(%{state | eof_seq: seq})

      true ->
        send_ack(state)
    end
  end

  defp maybe_eof(%{eof_seq: nil} = state), do: state

  defp maybe_eof(state) do
    if state.ack_nr == (state.eof_seq - 1 &&& 0xFFFF) or state.ack_nr == state.eof_seq do
      %{state | eof_ready: true}
    else
      state
    end
  end

  defp eof_drained?(state) do
    state.eof_ready and byte_size(state.recv_app) == 0 and map_size(state.recv_buf) == 0
  end

  defp fulfill_waiters(state) do
    Enum.reduce(state.waiters, %{state | waiters: []}, fn {from, count}, acc ->
      cond do
        byte_size(acc.recv_app) >= count ->
          <<data::binary-size(^count), rest::binary>> = acc.recv_app
          GenServer.reply(from, {:ok, data})
          %{acc | recv_app: rest}

        eof_drained?(acc) or acc.status == :closed ->
          GenServer.reply(from, {:error, :closed})
          acc

        true ->
          %{acc | waiters: acc.waiters ++ [{from, count}]}
      end
    end)
  end

  defp fulfill_connect(%{connect_from: nil} = state), do: state

  defp fulfill_connect(%{connect_from: from} = state) do
    GenServer.reply(from, :ok)
    %{state | connect_from: nil}
  end

  # -- send path ---------------------------------------------------------

  defp pump(%{send_queue: []} = state), do: state

  defp pump(state) do
    [head | tail] = state.send_queue
    {chunk, rest} = split_chunk(head)
    bytes = byte_size(chunk)

    if in_flight(state) == 0 or in_flight(state) + bytes <= min(state.max_window, state.adv_wnd) do
      seq = state.seq_next
      send_pkt(state, :data, chunk, seq)
      state = record_send(state, :data, chunk, seq)
      queue = if rest == <<>>, do: tail, else: [rest | tail]
      pump(%{state | send_queue: queue, queued_bytes: state.queued_bytes - bytes})
    else
      state
    end
  end

  defp split_chunk(bin) when byte_size(bin) > @payload_max do
    <<chunk::binary-size(@payload_max), rest::binary>> = bin
    {chunk, rest}
  end

  defp split_chunk(bin), do: {bin, <<>>}

  defp in_flight(state) do
    Enum.sum(Enum.map(state.send_buf, fn {_seq, payload, _kind, _, _} -> byte_size(payload) end))
  end

  defp record_send(state, kind, payload, seq) do
    entry = {seq, payload, kind, now_ms(), 1}

    %{state | send_buf: state.send_buf ++ [entry], seq_next: seq + 1 &&& 0xFFFF}
  end

  defp send_ack(state) do
    sack =
      if map_size(state.recv_buf) > 0 do
        MapSet.new(Map.keys(state.recv_buf))
      else
        nil
      end

    send_pkt(state, :state, <<>>, state.seq_next, sack)
    state
  end

  defp send_pkt(state, type, payload, seq, sack \\ nil) do
    opts = if sack == nil, do: [], else: [sack: sack]

    header = %{
      type: type,
      conn_id: state.send_id,
      ts: now_us() &&& 0xFFFFFFFF,
      ts_diff: state.reply_micro,
      wnd: adv_window(state),
      seq: seq,
      ack: state.ack_nr
    }

    bytes = Utp.encode(header, opts) <> payload
    :gen_udp.send(state.udp, state.peer_ip, state.peer_port, bytes)
  end

  defp adv_window(state) do
    buffered =
      byte_size(state.recv_app) +
        Enum.sum(Enum.map(state.recv_buf, fn {_seq, payload} -> byte_size(payload) end))

    max(0, @recv_cap - buffered)
  end

  # -- timers, samples, death --------------------------------------------

  defp on_tick(state) do
    now = now_ms()

    cond do
      state.status == :connecting and now > state.connect_deadline ->
        if state.connect_from != nil, do: GenServer.reply(state.connect_from, {:error, :timeout})
        die_closed(%{state | connect_from: nil}, :timeout)

      state.status == :connecting ->
        maybe_timeout_resend(state, now)

      state.status == :closed or state.status == :fin_sent ->
        state

      true ->
        maybe_timeout_resend(state, now)
    end
  end

  defp maybe_timeout_resend(%{send_buf: []} = state, _now), do: state

  defp maybe_timeout_resend(state, now) do
    [{seq, payload, kind, sent_at, count} | _] = state.send_buf

    if now - sent_at > state.timeout_ms do
      send_pkt(state, kind, payload, seq)

      send_buf =
        List.keyreplace(state.send_buf, seq, 0, {seq, payload, kind, now, count + 1})

      %{
        state
        | send_buf: send_buf,
          max_window: Utp.min_window_bytes(),
          timeouts_consec: state.timeouts_consec + 1
      }
      |> double_timeout()
      |> pump()
    else
      state
    end
  end

  defp double_timeout(state) do
    %{state | timeout_ms: min(state.timeout_ms * 2, @max_timeout_ms)}
  end

  defp note_sample(state, header) do
    now_us = now_us()
    reply_micro = now_us - header.ts &&& 0xFFFFFFFF

    samples = prune_samples([{header.ts_diff, now_ms()} | state.base_samples])

    base =
      case samples do
        [] -> nil
        _ -> samples |> Enum.map(&elem(&1, 0)) |> Enum.min()
      end

    state = %{
      state
      | reply_ts: header.ts,
        reply_micro: reply_micro,
        base_samples: samples,
        base_delay_us: base
    }

    if header.ts_diff != 0 and base != nil do
      our_delay = header.ts_diff - base &&& 0xFFFFFFFF
      # Sub-microsecond wraps read as huge delays; clamp to ±1 hour.
      our_delay = if our_delay > 0x80000000, do: 0, else: our_delay
      max_window = Utp.ledbat_update(state.max_window, in_flight(state), our_delay, @payload_max)
      %{state | max_window: max_window}
    else
      state
    end
  end

  defp prune_samples(samples) do
    cutoff = now_ms() - 120_000
    Enum.filter(samples, fn {_delay, at} -> at >= cutoff end)
  end

  defp die_closed(state, _reason) do
    state = %{state | status: :closed}

    if state.connect_from != nil do
      GenServer.reply(state.connect_from, {:error, :closed})
    end

    fulfill_waiters(%{state | connect_from: nil})
  end

  defp cleanup(state) do
    :gen_udp.close(state.udp)
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_us, do: System.monotonic_time(:microsecond)
end
