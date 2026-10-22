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

  @block_size 16_384
  @handshake_size 68
  @recv_timeout 10_000
  @max_inflight 5
  @piece_timeout 30_000

  @doc """
  Start an unnamed worker downloading `piece_index` from `peer`.

  Required opts: `:peer`, `:info_hash` (20-byte binary), `:peer_id`
  (20-byte binary), `:info` (torrent info map), `:piece_index`,
  `:piece_hash` (20-byte expected SHA1), `:base_dir`. Seams: `:network`
  (default `TorrentClient.Network`), `:disk` (default
  `TorrentClient.Disk`), `:sock` (default
  `TorrentClient.GenTcpSocket`, implementing
  `TorrentClient.SocketBehaviour`), `:clock` (default
  `TorrentClient.Clock`), `:recv_timeout` ms (default
  #{@recv_timeout}). Pipeline: `:max_inflight` outstanding block requests
  (default #{@max_inflight}), `:piece_timeout` ms for the whole piece
  (default #{@piece_timeout}), `:report_to` pid receiving
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
      recv_timeout: Keyword.get(opts, :recv_timeout, @recv_timeout),
      max_inflight: Keyword.get(opts, :max_inflight, @max_inflight),
      piece_timeout: Keyword.get(opts, :piece_timeout, @piece_timeout),
      report_to: Keyword.get(opts, :report_to, nil),
      socket: nil,
      deadline_at: nil,
      peer_state: PeerState.init(),
      bitfield_seen: false,
      blocks: [],
      inflight: [],
      received: %{}
    }

    case Torrent.piece_span(state.info, state.piece_index) do
      {:ok, {_offset, size}} ->
        {:ok, %{state | blocks: split_blocks(size)}, {:continue, :connect}}

      {:error, _} ->
        {:stop, :invalid_piece}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case state.network.connect(state.peer) do
      {:ok, socket} ->
        state = %{state | socket: socket}

        case handshake(state) do
          :ok ->
            serve(%{state | deadline_at: state.clock.monotonic_ms() + state.piece_timeout})

          {:error, reason} ->
            {:stop, reason, state}
        end

      {:error, reason} ->
        {:stop, {:connect_failed, reason}, state}
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

  # Full BEP-3 greeting: send our handshake, read theirs (exactly 68 bytes,
  # so a co-segmented bitfield stays buffered), fail closed on mismatch,
  # then announce interest and unchoke the peer.
  defp handshake(state) do
    out = Handshake.init(state.info_hash, state.peer_id) |> Handshake.serialize()
    info_hash = state.info_hash

    with :ok <- tcp_send(state.sock, state.socket, out),
         {:ok, bytes} <- recv_exact(state.sock, state.socket, @handshake_size, state.recv_timeout),
         {:ok, %Handshake{info_hash: ^info_hash}} <- safe_deserialize(bytes),
         :ok <- send_message(state.sock, state.socket, %Interested{}),
         :ok <- send_message(state.sock, state.socket, %Unchoke{}) do
      :ok
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
  defp send_message(sock, socket, message) do
    {:ok, bytes} = PeerMessage.encode(message)
    tcp_send(sock, socket, bytes)
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
    Enum.reduce_while(state.inflight, :ok, fn {begin, length}, :ok ->
      case send_message(state.sock, state.socket, %Cancel{
             index: state.piece_index,
             begin: begin,
             length: length
           }) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:stop, :normal, state}
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
    not state.peer_state.peer_choking and length(state.inflight) < state.max_inflight and
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

      case send_message(state.sock, state.socket, request) do
        :ok -> fill_pipeline(%{state | inflight: [{begin, length} | state.inflight]})
        {:error, reason} -> {:stop, reason, state}
      end
    else
      await_message(state)
    end
  end

  defp await_message(state) do
    case recv_message(state) do
      {:ok, message} ->
        dispatch(state, message)

      {:error, :peer_timeout} ->
        if deadline_exceeded?(state) do
          give_up(state)
        else
          {:stop, :peer_timeout, state}
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
      state = %{state | received: Map.put(state.received, begin, block)}
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

  # Each receive is bounded by the nearer of the per-message timeout and
  # the remaining piece deadline, so a silent peer trips the deadline
  # instead of hanging on a full recv timeout.
  defp recv_budget(state) do
    min(state.recv_timeout, max(state.deadline_at - state.clock.monotonic_ms(), 0))
  end

  defp recv_message(state) do
    with {:ok, <<length::32-big>>} <- recv_exact(state.sock, state.socket, 4, recv_budget(state)) do
      if length == 0 do
        {:ok, %KeepAlive{}}
      else
        recv_payload(state, length)
      end
    end
  end

  # Exact framing: payload holds precisely one message, so the decoded
  # rest is always empty and any error is fail-closed.
  defp recv_payload(state, length) do
    with {:ok, payload} <- recv_exact(state.sock, state.socket, length, recv_budget(state)),
         {:ok, message, _rest} <- PeerMessage.decode(<<length::32-big, payload::binary>>) do
      {:ok, message}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_exact(sock, socket, count, timeout) do
    case sock.recv(socket, count, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :timeout} -> {:error, :peer_timeout}
      {:error, :closed} -> {:error, :peer_closed}
      {:error, reason} -> {:error, reason}
    end
  end

  # A dead socket raises instead of answering: fail closed so the
  # supervisor restarts with a fresh connection.
  defp tcp_send(sock, socket, bytes) do
    case sock.send(socket, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  rescue
    _ -> {:error, {:send_failed, :badarg}}
  end
end
