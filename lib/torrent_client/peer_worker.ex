defmodule TorrentClient.PeerWorker do
  @moduledoc """
  Unnamed peer GenServer: downloads one assigned piece over the BEP-3 wire.

  Owned one-for-one by `TorrentClient.PeerSupervisor`; never registered, so
  many workers share one node. The worker performs no retries itself — any
  connect, handshake, or protocol failure stops the process and the
  supervisor decides (transient child: abnormal exits restart bounded by the
  supervisor's intensity, `:normal` completion never restarts).

  Wire posture, per the ticket: assume choked until unchoked (requests go
  out only while unchoked), send `Interested` + `Unchoke` once the handshake
  completes, then request the piece in 16 KiB blocks with up to five in
  flight, verify the SHA1, and persist via the disk seam. Interleaved
  `Have`/`Bitfield`/`Choke` update the `PeerState`; anything malformed is
  an error stop, never a crash.

  A per-piece deadline (default 30 s) unsticks dead peers: when it fires,
  the worker publishes the missing blocks to `:report_to` (the coordinator
  requeues from that) and stops abnormally so the supervisor restarts it
  within its intensity. A choke drops in-flight requests; the next unchoke
  re-requests them (duplicates are idempotent).
  """

  use GenServer

  require Logger

  # Choke/NotInterested arrive too but need no name: the dispatch
  # catch-all routes every posture message through PeerState.handle/2.
  alias PeerMessage.{
    Bitfield,
    Cancel,
    Have,
    Interested,
    KeepAlive,
    Piece,
    Request,
    Unchoke
  }

  alias TorrentClient.{MSE, PeerPipeline}

  @block_size 16_384
  @handshake_size 68
  @recv_timeout 10_000
  @max_inflight 5
  @piece_timeout 30_000
  @first_byte_timeout 5_000
  @max_consecutive_timeouts 3

  @doc """
  Start an unnamed worker downloading `piece_index` from `peer`.

  Required opts: `:peer`, `:info_hash` (20-byte binary), `:peer_id`
  (20-byte binary), `:info` (torrent info map), `:piece_index`,
  `:piece_hash` (20-byte expected SHA1), `:base_dir`. Seams: `:network`
  (default `TorrentClient.Network`), `:disk` (default
  `TorrentClient.Disk`), `:sock` (default
  `TorrentClient.GenTcpSocket`, implementing
  `TorrentClient.SocketBehaviour`), `:clock` (default
  `TorrentClient.Clock`), `:encryption` (`:plaintext` default;
  `:prefer_mse` tries the MSE/PE encrypted handshake and falls back to
  plaintext on a fresh connection when the peer speaks none;
  `:require_mse` fails closed instead), `:recv_timeout` ms (default
  #{@recv_timeout}). Pipeline: up to `:max_inflight` outstanding block
  requests (default #{@max_inflight}), adapting to the peer by additive
  increase / multiplicative decrease (one more outstanding block per
  window of sustained receipts, halved on timeout) with the receive
  timeout derived from observed block latency, so fast links deepen
  past the starting depth of 5 and jittery ones back off instead of
  dying. `:piece_timeout` ms for the whole piece
  (default #{@piece_timeout}), `:first_byte_timeout` ms for the first
  received block (default #{@first_byte_timeout}: a peer that sends
  nothing that fast is poison, fail it without waiting out the piece),
  `:report_to` pid receiving
  `{:piece_timeout, index, missing}` on give-up (default `nil`). When set,
  it also receives `{:piece_complete, pid, index}` after a verified write
  (`pid` is the reporting worker, so the coordinator attributes bytes
  exactly even with endgame duplicates),
  `{:block_progress, index}` per accepted block, and `{:availability,
  worker_pid, set}` whenever the peer's known pieces grow (bitfield or
  `Have`). The coordinator consumes these; the worker never blocks on
  them.

  A raw `{:cancel_piece, index}` message (sent with `send/2`, not a
  GenServer call, so it lands while the worker is mid-piece) cancels
  every outstanding request on the wire with `Cancel` messages and stops
  normally — the piece was already verified elsewhere. Stale indices
  are ignored.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Transient: `:normal` completion never restarts; abnormal exits restart
  # via the supervisor, bounded by its intensity.
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @impl true
  def init(opts) do
    state = %{
      peer: Keyword.fetch!(opts, :peer),
      info_hash: Keyword.fetch!(opts, :info_hash),
      peer_id: Keyword.fetch!(opts, :peer_id),
      info: Keyword.fetch!(opts, :info),
      piece_index: Keyword.fetch!(opts, :piece_index),
      piece_hash: Keyword.fetch!(opts, :piece_hash),
      base_dir: Keyword.fetch!(opts, :base_dir),
      network: Keyword.get(opts, :network, TorrentClient.Network),
      disk: Keyword.get(opts, :disk, TorrentClient.Disk),
      sock: Keyword.get(opts, :sock, TorrentClient.GenTcpSocket),
      clock: Keyword.get(opts, :clock, TorrentClient.Clock),
      encryption: Keyword.get(opts, :encryption, :plaintext),
      crypto: nil,
      recv_timeout: Keyword.get(opts, :recv_timeout, @recv_timeout),
      max_inflight: Keyword.get(opts, :max_inflight, @max_inflight),
      piece_timeout: Keyword.get(opts, :piece_timeout, @piece_timeout),
      first_byte_timeout: Keyword.get(opts, :first_byte_timeout, @first_byte_timeout),
      pipeline: PeerPipeline.init(Keyword.get(opts, :max_inflight, @max_inflight)),
      report_to: Keyword.get(opts, :report_to, nil),
      socket: nil,
      deadline_at: nil,
      served_at: nil,
      last_send_at: nil,
      peer_state: PeerState.init(),
      bitfield_seen: false,
      blocks: [],
      inflight: [],
      received: %{}
    }

    if state.encryption in [:plaintext, :prefer_mse, :require_mse] do
      case Torrent.piece_span(state.info, state.piece_index) do
        {:ok, {_offset, size}} ->
          {:ok, %{state | blocks: split_blocks(size)}, {:continue, :connect}}

        {:error, _} ->
          {:stop, :invalid_piece}
      end
    else
      {:stop, :invalid_encryption}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_and_greet(state) do
      {:ok, state} ->
        now = state.clock.monotonic_ms()

        serve(%{
          state
          | deadline_at: now + state.piece_timeout,
            served_at: now,
            last_send_at: now
        })

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp connect_and_greet(state) do
    case connect(state) do
      {:ok, socket} -> greet_connected(state, socket)
      {:error, _} = err -> err
    end
  end

  defp greet_connected(state, socket) do
    case greet(%{state | socket: socket}, state.encryption) do
      {:ok, _} = ok ->
        ok

      {:error, {:mse_failed, _}} when state.encryption == :prefer_mse ->
        # The optimistic MSE bytes desynchronize this stream, so the
        # fallback needs a fresh connection, not a re-read.
        if is_port(socket), do: state.sock.close(socket)

        with {:ok, retry} <- connect(state),
             {:ok, _} = ok <- greet(%{state | socket: retry, crypto: nil}, :plaintext) do
          ok
        end

      {:error, _} = err ->
        err
    end
  end

  defp connect(state) do
    case state.network.connect(state.peer) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  # The socket dies with the worker, but an explicit close keeps restarts
  # from stacking duplicate connections on the crash path.
  @impl true
  def terminate(_reason, %{socket: socket, sock: sock}) when is_port(socket),
    do: sock.close(socket)

  def terminate(_reason, _state), do: :ok

  defp split_blocks(size) do
    for begin <- Range.new(0, size - 1, @block_size) do
      {begin, min(@block_size, size - begin)}
    end
  end

  defp greet(state, :plaintext), do: greet_plaintext(state)
  defp greet(state, :prefer_mse), do: greet_mse(state)
  defp greet(state, :require_mse), do: greet_mse(state)

  # Full BEP-3 greeting: send our handshake, read theirs (exactly 68 bytes,
  # so a co-segmented bitfield stays buffered), fail closed on mismatch,
  # then announce interest and unchoke the peer.
  defp greet_plaintext(state) do
    out = Handshake.init(state.info_hash, state.peer_id) |> Handshake.serialize()

    with {:ok, state} <- send_bytes(state, out) do
      arm_peer(state)
    end
  end

  # MSE/PE initiator: DH hello, then the encrypted step 3 carrying our BT
  # handshake as IA, then the peer's handshake off the negotiated stream.
  # Every failure wraps as {:mse_failed, reason} so :prefer_mse can tell
  # a dead encryption attempt from a dead peer; the armed greeting inside
  # passes its own errors through unwrapped (it is the with-body, not a step).
  defp greet_mse(state) do
    priv = MSE.generate_private()
    hello = MSE.public_key(priv) <> MSE.random_pad()

    with {:ok, state} <- send_bytes(state, hello),
         {:ok, yb, state} <- recv_exact(state, 96, state.recv_timeout),
         {:ok, secret} <- MSE.shared_secret(yb, priv),
         {:ok, state} <- mse_negotiate(state, secret) do
      arm_peer(state)
    else
      {:error, reason} -> {:error, {:mse_failed, reason}}
    end
  end

  defp mse_negotiate(state, secret) do
    info_hash = state.info_hash
    ia = Handshake.init(info_hash, state.peer_id) |> Handshake.serialize()
    step3 = MSE.build_step3(secret, info_hash, ia)

    with {:ok, state} <- send_bytes(state, step3),
         {:ok, recv_stream, state} <- mse_read_select(state, secret, info_hash, <<>>) do
      # The payload stream continues the step-3 stream: fast-forward past
      # its encrypted bytes (everything after the plaintext req1 + proof).
      send_stream =
        MSE.rc4_skip(MSE.stream_key(secret, info_hash, :initiator), byte_size(step3) - 40)

      {:ok, %{state | crypto: %{send: send_stream, recv: recv_stream}}}
    end
  end

  # The peer's PadB junk has unknown length, so the VC resync reads one
  # byte at a time: the only granularity with no overshoot, which keeps
  # later stream bytes in the socket instead of a readahead buffer. Only
  # windows touching the new byte can match (older ones already missed),
  # so each step scans just the last 15 bytes.
  defp mse_read_select(state, secret, skey, buf) do
    case scan_new_vc(buf, secret, skey) do
      {:ok, offset} -> mse_read_rest(state, secret, skey, buf, offset)
      {:error, :vc_not_found} -> mse_read_more(state, secret, skey, buf)
    end
  end

  defp mse_read_more(state, secret, skey, buf) do
    if byte_size(buf) > 630 do
      {:error, :vc_not_found}
    else
      case recv_exact(state, 1, state.recv_timeout) do
        {:ok, byte, state} -> mse_read_select(state, secret, skey, buf <> byte)
        {:error, _} = err -> err
      end
    end
  end

  defp scan_new_vc(buf, secret, skey) do
    len = byte_size(buf)
    from = max(len - 15, 0)
    tail = binary_part(buf, from, len - from)

    case MSE.scan_for_vc(tail, secret, skey) do
      {:ok, rel} -> {:ok, from + rel}
      {:error, _} = err -> err
    end
  end

  defp mse_read_rest(state, secret, skey, buf, offset) do
    key = MSE.stream_key(secret, skey, :responder)

    with {:ok, buf, state} <- recv_more(state, buf, offset + 14),
         # Peek, not consume: the stream parse below replays these exact
         # bytes so keystream positions match the peer's continuous stream.
         <<_vc::64, _select::32-big, len_d::16-big>> =
           MSE.rc4_oneshot(key, binary_part(buf, offset, 14)),
         total = offset + 14 + len_d,
         {:ok, buf, state} <- recv_more(state, buf, total),
         stream = MSE.rc4_new(key),
         cipher = binary_part(buf, offset, total - offset),
         {:ok, :rc4, recv_stream} <- MSE.parse_step4_stream(stream, cipher) do
      {:ok, recv_stream, state}
    end
  end

  defp recv_more(state, buf, want) when byte_size(buf) >= want, do: {:ok, buf, state}

  defp recv_more(state, buf, want) do
    case recv_exact(state, want - byte_size(buf), state.recv_timeout) do
      {:ok, data, state} -> recv_more(state, buf <> data, want)
      {:error, _} = err -> err
    end
  end

  defp arm_peer(state) do
    info_hash = state.info_hash

    with {:ok, bytes, state} <- recv_exact(state, @handshake_size, state.recv_timeout),
         {:ok, %Handshake{info_hash: ^info_hash}} <- safe_deserialize(bytes),
         {:ok, state} <- send_message(state, %Interested{}),
         {:ok, state} <- send_message(state, %Unchoke{}) do
      {:ok, state}
    else
      {:ok, %Handshake{}} -> {:error, :info_hash_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_deserialize(bytes) do
    Handshake.deserialize(bytes)
  rescue
    _ -> {:error, :bad_handshake}
  end

  # All worker-sent messages are statically valid (block splits cap
  # request lengths), so encoding cannot fail: the match is an assertion.
  # Bytes leave through the RC4 stream once MSE negotiated it.
  defp send_message(state, message) do
    {:ok, bytes} = PeerMessage.encode(message)
    send_bytes(state, bytes)
  end

  defp send_bytes(state, bytes) do
    case tcp_send(state.sock, state.socket, bytes, state.crypto) do
      {:ok, crypto} -> {:ok, %{state | crypto: crypto}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Loop: finish when every block is in, give up at the deadline, stop
  # normally when a seen bitfield proves the peer lacks our piece, else
  # fill the pipeline and wait for answers. The cancel drain runs first
  # so an endgame loser stops even while blocks are still arriving: the
  # non-{:cont, _} passthrough keeps every callback return valid.
  defp serve(state) do
    with {:cont, state} <- drain_cancel(state) do
      cond do
        complete?(state) -> verify_and_write(state)
        first_byte_due?(state) -> give_up(state)
        deadline_exceeded?(state) -> give_up(state)
        known_missing?(state) -> {:stop, :normal, state}
        true -> fill_pipeline(state)
      end
    end
  end

  # Non-blocking poll: the worker lives inside one handle_continue, so
  # GenServer casts would only run after the piece finishes. Raw sends
  # are picked up here, once per loop iteration (keepalives keep a
  # stalled peer iterating).
  defp drain_cancel(state) do
    receive do
      {:cancel_piece, index} -> cancel_inflight(state, index)
    after
      0 -> {:cont, state}
    end
  end

  defp cancel_inflight(%{piece_index: piece} = state, piece) do
    # The crypto stream advances per send, so the state threads through.
    Enum.reduce_while(state.inflight, {:ok, state}, fn {begin, length}, {:ok, state} ->
      case send_message(state, %Cancel{
             index: state.piece_index,
             begin: begin,
             length: length
           }) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, state} -> {:stop, :normal, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp cancel_inflight(state, _stale_index), do: {:cont, state}

  defp deadline_exceeded?(state) do
    state.clock.monotonic_ms() >= state.deadline_at
  end

  defp known_missing?(state) do
    state.bitfield_seen and state.inflight == [] and next_block(state) != nil and
      state.piece_index not in PeerState.available_indices(state.peer_state)
  end

  # Give up with the missing set published: the report lets the coordinator
  # requeue exactly these blocks, and the abnormal reason restarts the worker
  # within the supervisor's intensity for transient blips.
  defp give_up(state) do
    missing =
      for {begin, length} <- state.blocks, not Map.has_key?(state.received, begin) do
        {begin, length}
      end

    case state.report_to do
      nil -> :ok
      pid -> send(pid, {:piece_timeout, state.piece_index, missing})
    end

    {:stop, {:piece_timeout, state.piece_index, missing}, state}
  end

  defp complete?(state) do
    Enum.sum(Enum.map(state.received, fn {_begin, block} -> byte_size(block) end)) ==
      piece_size(state) and piece_size(state) > 0
  end

  defp piece_size(state) do
    Enum.sum(Enum.map(state.blocks, fn {_begin, length} -> length end))
  end

  defp sendable?(state) do
    not state.peer_state.peer_choking and length(state.inflight) < state.pipeline.depth and
      next_block(state) != nil and peer_may_have?(state)
  end

  defp peer_may_have?(state) do
    not state.bitfield_seen or
      state.piece_index in PeerState.available_indices(state.peer_state)
  end

  defp next_block(state) do
    Enum.find(state.blocks, fn {begin, _length} ->
      not Map.has_key?(state.received, begin) and List.keyfind(state.inflight, begin, 0) == nil
    end)
  end

  # Send while the peer may have more for us and the pipeline has room,
  # then wait for answers. A send failure stops fail-closed.
  defp fill_pipeline(state) do
    if sendable?(state) do
      {begin, length} = next_block(state)
      request = %Request{index: state.piece_index, begin: begin, length: length}

      case send_message(state, request) do
        {:ok, state} ->
          fill_pipeline(%{
            state
            | inflight: [{begin, length} | state.inflight],
              last_send_at: state.clock.monotonic_ms()
          })

        {:error, reason} ->
          {:stop, reason, state}
      end
    else
      await_message(state)
    end
  end

  defp await_message(state) do
    case recv_message(state) do
      {:ok, message, state} ->
        dispatch(state, message)

      {:error, :peer_timeout} ->
        cond do
          deadline_exceeded?(state) ->
            give_up(state)

          state.pipeline.consecutive_timeouts + 1 >= @max_consecutive_timeouts ->
            # A timeout mid-frame leaves the stream desynchronized, so
            # sustained silence can never complete: give up and let a
            # fresh connection retry instead of spinning to the deadline.
            give_up(%{state | pipeline: PeerPipeline.note_timeout(state.pipeline)})

          true ->
            # Congestion signal, not death: halve the depth, drop the
            # unanswered batch for re-request, and keep serving. Poison
            # peers (zero bytes) trip the first-byte deadline instead.
            pipeline = PeerPipeline.note_timeout(state.pipeline)
            serve(%{state | pipeline: pipeline, inflight: []})
        end

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  # Peer postures evolve the shared PeerState; requests for our bytes are
  # ignored (kog.8 never serves uploads); pieces assemble below.
  defp dispatch(state, %Piece{} = message), do: handle_piece(state, message)
  defp dispatch(state, %Request{}), do: serve(state)
  defp dispatch(state, %Cancel{}), do: serve(state)
  defp dispatch(state, %KeepAlive{}), do: serve(state)
  defp dispatch(state, message), do: handle_posture(track(state, message), message)

  defp track(state, %Bitfield{}), do: %{state | bitfield_seen: true}
  defp track(state, %Have{}), do: %{state | bitfield_seen: true}
  defp track(state, _message), do: state

  defp handle_posture(state, message) do
    case PeerState.handle(state.peer_state, message) do
      {:ok, peer_state} ->
        # A fresh unchoke re-arms the pipeline: peers may drop requests on
        # choke, and duplicate blocks are idempotent.
        inflight = if match?(%Unchoke{}, message), do: [], else: state.inflight
        state = %{state | peer_state: peer_state, inflight: inflight}
        report_availability(state, message)
        serve(state)

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  # The coordinator plans rarest-first from these; only bitfield and
  # Have grow the known set, so only they report.
  defp report_availability(state, %Bitfield{}),
    do: report(state, {:availability, self(), PeerState.available_indices(state.peer_state)})

  defp report_availability(state, %Have{}),
    do: report(state, {:availability, self(), PeerState.available_indices(state.peer_state)})

  defp report_availability(_state, _message), do: :ok

  # Only the exact requested slice is accepted: a short or overlapping
  # block would poison the assembly and hang the worker on a sum that can
  # never complete, so anything off-plan is a protocol error stop.
  defp handle_piece(state, %Piece{index: index, begin: begin, block: block}) do
    if index == state.piece_index and
         List.keyfind(state.blocks, begin, 0) == {begin, byte_size(block)} and
         Torrent.validate_block(state.info, index, begin, block) == :ok do
      now = state.clock.monotonic_ms()

      pipeline = PeerPipeline.note_received(state.pipeline, state.last_send_at, now)
      state = %{state | received: Map.put(state.received, begin, block), pipeline: pipeline}
      report(state, {:block_progress, index})
      serve(%{state | inflight: List.keydelete(state.inflight, begin, 0)})
    else
      {:stop, :unexpected_piece, state}
    end
  end

  defp verify_and_write(state) do
    data = assemble(state)

    if Torrent.verify_hash?(data, state.piece_hash) do
      write_verified(state, data)
    else
      {:stop, :piece_mismatch, state}
    end
  end

  defp assemble(state) do
    state.received
    |> Enum.sort_by(fn {begin, _block} -> begin end)
    |> Enum.map_join("", &elem(&1, 1))
  end

  defp write_verified(state, data) do
    case state.disk.write_piece(state.base_dir, state.info, state.piece_index, data) do
      :ok ->
        Logger.debug("Piece #{state.piece_index} verified and written")
        report(state, {:piece_complete, self(), state.piece_index})
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, {:disk_error, reason}, state}
    end
  end

  # Best-effort upward reports: the coordinator may be gone, and the
  # worker must never block on it.
  defp report(%{report_to: nil}, _message), do: :ok
  defp report(%{report_to: pid}, message), do: send(pid, message)

  # Each receive is bounded by the nearer of the adaptive per-message
  # timeout (triple the observed block latency within floor and the
  # configured ceiling) and the remaining piece deadline, so a silent
  # peer trips the deadline instead of hanging on a full recv timeout.
  defp recv_budget(state) do
    recv_timeout = PeerPipeline.recv_timeout(state.pipeline, state.recv_timeout)
    min(recv_timeout, max(state.deadline_at - state.clock.monotonic_ms(), 0))
  end

  # Zero bytes within the first-byte budget is the poison shape: fail
  # the piece fast so the coordinator's failure budget skips the peer
  # in seconds instead of after full piece deadlines.
  defp first_byte_due?(state) do
    PeerPipeline.first_byte_due?(
      state.pipeline,
      state.served_at,
      state.clock.monotonic_ms(),
      state.first_byte_timeout
    )
  end

  defp recv_message(state) do
    with {:ok, <<length::32-big>>, state} <- recv_exact(state, 4, recv_budget(state)) do
      if length == 0 do
        {:ok, %KeepAlive{}, state}
      else
        recv_payload(state, length)
      end
    end
  end

  # Exact framing: payload holds precisely one message, so the decoded
  # rest is always empty and any error is fail-closed.
  defp recv_payload(state, length) do
    with {:ok, payload, state} <- recv_exact(state, length, recv_budget(state)),
         {:ok, message, _rest} <- PeerMessage.decode(<<length::32-big, payload::binary>>) do
      {:ok, message, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_exact(state, count, timeout) do
    case state.sock.recv(state.socket, count, timeout) do
      {:ok, data} -> decrypt(data, state)
      {:error, :timeout} -> {:error, :peer_timeout}
      {:error, :closed} -> {:error, :peer_closed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decrypt(data, %{crypto: nil} = state), do: {:ok, data, state}

  defp decrypt(data, %{crypto: crypto} = state) do
    {recv_state, plain} = MSE.rc4_crypt(crypto.recv, data)
    {:ok, plain, %{state | crypto: %{crypto | recv: recv_state}}}
  end

  # A dead socket raises instead of answering: fail closed so the
  # supervisor restarts with a fresh connection.
  defp tcp_send(sock, socket, bytes, nil) do
    case sock.send(socket, bytes) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  rescue
    _ -> {:error, {:send_failed, :badarg}}
  end

  defp tcp_send(sock, socket, bytes, crypto) do
    {send_state, cipher} = MSE.rc4_crypt(crypto.send, bytes)

    case sock.send(socket, cipher) do
      :ok -> {:ok, %{crypto | send: send_state}}
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  rescue
    _ -> {:error, {:send_failed, :badarg}}
  end
end
