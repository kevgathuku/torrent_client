defmodule TorrentClient.Coordinator do
  @moduledoc """
  Per-torrent download coordinator: owns all torrent state, assigns
  pieces to peer workers rarest-first, and watches for stalls.

  Workers are one-piece `PeerWorker` processes owned by the sibling
  `PeerSupervisor`; they report upward (`:availability`, `:block_progress`,
  `:piece_complete`, `:piece_timeout`) and never share state. The
  coordinator monitors every worker it starts:

  - `:normal` exit with the piece verified means done (completion message
    always arrives first); `:normal` without verification means the peer
    lacks the piece, so it is recorded missing and the piece requeues.
  - Abnormal exits requeue the piece and count against the peer; past the
    failure budget the peer is skipped. Restarted orphans (the supervisor
    restarts abnormal exits with the same piece) are terminated on sight,
    so every live worker is coordinator-assigned — their completion
    messages still count if they win the race.
  - Endgame (nothing unassigned, pieces still out) duplicates an in-flight
    piece onto an idle peer; the first completion cancels the losers, and
    the losers' `Cancel` messages go out on the wire via kog.4 codec.

  The watchdog fires when no block completes within the budget: workers
  are terminated and their pieces requeued for fresh dials. Past the stall
  budget the coordinator reports `{:download_stalled, info_hash}` and stops
  `:normal`; with no workers and no assignable pieces left it reports
  `{:swarm_exhausted, info_hash}` and stops `:normal`. Terminal stops
  never restart (transient child, `:normal` exit), so the session above
  owns retry policy. On full verification it reports
  `{:torrent_complete, info_hash}` and stops `:normal`.

  Skipped peers (past the failure budget) are announced as
  `{:peer_skipped, {ip, port}}` reports.
  """

  use GenServer

  require Logger

  alias TorrentClient.PeerWorker

  @default_max_peers 4
  @default_max_inflight 5
  @default_watchdog_timeout 60_000
  @default_max_stalls 3
  @default_max_peer_failures 3

  @doc """
  Start the coordinator. Required: `:info` (torrent info map),
  `:info_hash` (20-byte binary), `:piece_hashes` (list of 20-byte SHA1s,
  one per piece), `:base_dir`, `:peer_sup` (peer supervisor name or pid).
  Optional: `:peers` (static peer list), `:peer_id`, `:report_to`,
  `:max_peers` (default #{@default_max_peers}), `:max_inflight`,
  `:watchdog_timeout` ms, `:max_stalls`, `:max_peer_failures`,
  `:recv_timeout`/`:piece_timeout` ms passed to workers, effect seams
  (`:network`, `:disk`, `:sock`, `:clock`), `:name`.
  """
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    piece_hashes = Keyword.fetch!(opts, :piece_hashes)
    now = clock(opts).monotonic_ms()

    state = %{
      info: Keyword.fetch!(opts, :info),
      info_hash: Keyword.fetch!(opts, :info_hash),
      piece_hashes: piece_hashes,
      total: length(piece_hashes),
      base_dir: Keyword.fetch!(opts, :base_dir),
      peer_id: Keyword.get(opts, :peer_id, Utils.generate_peer_id()),
      peers: Keyword.get(opts, :peers, []),
      max_peers: Keyword.get(opts, :max_peers, @default_max_peers),
      max_inflight: Keyword.get(opts, :max_inflight, @default_max_inflight),
      watchdog_timeout: Keyword.get(opts, :watchdog_timeout, @default_watchdog_timeout),
      max_stalls: Keyword.get(opts, :max_stalls, @default_max_stalls),
      max_peer_failures: Keyword.get(opts, :max_peer_failures, @default_max_peer_failures),
      recv_timeout: Keyword.get(opts, :recv_timeout, 10_000),
      piece_timeout: Keyword.get(opts, :piece_timeout, 30_000),
      report_to: Keyword.get(opts, :report_to, nil),
      clock: Keyword.get(opts, :clock, TorrentClient.Clock),
      network: Keyword.get(opts, :network, TorrentClient.Network),
      disk: Keyword.get(opts, :disk, TorrentClient.Disk),
      sock: Keyword.get(opts, :sock, TorrentClient.GenTcpSocket),
      sup: Keyword.fetch!(opts, :peer_sup),
      download: DownloadState.init(length(piece_hashes)) |> DownloadState.note_progress(now),
      workers: %{},
      availability: %{},
      missing: %{},
      failures: %{},
      skipped: MapSet.new(),
      stall_count: 0
    }

    reap_orphans(state)
    schedule_watchdog(state)
    state = try_assign(state)

    if swarm_exhausted?(state) do
      if state.report_to, do: send(state.report_to, {:swarm_exhausted, state.info_hash})
      {:stop, :swarm_exhausted}
    else
      {:ok, state}
    end
  end

  # Crash-path cleanup: terminating the coordinator must not strand live
  # workers under the sibling supervisor. The next incarnation would reap
  # them on init, but an explicit sweep here keeps terminal stops quiet
  # immediately (no orphan restarts against dead seeds). Best-effort: a
  # dead supervisor simply has nothing to reap.
  @impl true
  def terminate(:normal, _state), do: :ok

  def terminate(_reason, state) do
    reap_orphans(state)
    :ok
  end

  # -- worker reports ------------------------------------------------------

  @impl true
  def handle_info({:availability, pid, available}, state) do
    state =
      case Map.fetch(state.workers, pid) do
        {:ok, %{peer: peer}} ->
          %{state | availability: Map.put(state.availability, peer_key(peer), available)}

        :error ->
          state
      end

    {:noreply, try_assign(state)}
  end

  def handle_info({:block_progress, _index}, state) do
    {:noreply, note_progress(state)}
  end

  def handle_info({:piece_complete, index}, state) do
    state = state |> complete_piece(index) |> note_progress()
    cancel_duplicates(state, index)
    finish_or_assign(state)
  end

  # The abnormal DOWN that follows carries the retry decision; the report
  # itself is only a heads-up.
  def handle_info({:piece_timeout, index, _missing}, state) do
    Logger.debug("Piece #{index} timed out on its worker")
    {:noreply, state}
  end

  # -- worker exits ----------------------------------------------------------

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.workers, pid) do
      {nil, _} ->
        {:noreply, state}

      {%{peer: peer, index: index}, workers} ->
        state = %{state | workers: workers}

        state =
          if reason == :normal and verified?(state, index) do
            forget_failure(state, peer)
          else
            fail_assignment(state, peer, index, reason)
          end

        reap_orphans(state)
        finish_or_exhaust(state)
    end
  end

  def handle_info(:watchdog_check, state) do
    now = state.clock.monotonic_ms()

    case check_watchdog(state, now) do
      {:stop, _, _} = stop ->
        stop

      state ->
        schedule_watchdog(state)
        finish_or_exhaust(state)
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # -- assignment ------------------------------------------------------------

  defp finish_or_assign(state) do
    if DownloadState.complete?(state.download) do
      finish(state)
    else
      {:noreply, try_assign(state)}
    end
  end

  defp finish_or_exhaust(state) do
    cond do
      DownloadState.complete?(state.download) -> finish(state)
      swarm_exhausted?(state) -> give_up(state, :swarm_exhausted)
      true -> {:noreply, try_assign(state)}
    end
  end

  # Terminal give-up: report so the session can react, then stop
  # normally. Transient children never restart a `:normal` exit, so no
  # give-up loop can spin here; retry policy belongs to the session.
  defp give_up(state, reason) do
    if state.report_to, do: send(state.report_to, {reason, state.info_hash})
    {:stop, :normal, state}
  end

  defp finish(state) do
    # Losers exit on their own via the cancel just sent; terminating
    # them here would win the race and the Cancel would never reach the
    # wire. Stragglers are reaped by terminate/2 on abnormal stops.
    if state.report_to, do: send(state.report_to, {:torrent_complete, state.info_hash})
    {:stop, :normal, state}
  end

  defp swarm_exhausted?(state) do
    map_size(state.workers) == 0 and not DownloadState.complete?(state.download) and
      next_assignment(state) == :none
  end

  defp try_assign(state) do
    if map_size(state.workers) < state.max_peers do
      assign_one(state)
    else
      state
    end
  end

  defp assign_one(state) do
    case next_assignment(state) do
      {:ok, peer, index, download} ->
        case start_worker(state, peer, index) do
          {:ok, state} -> try_assign(%{state | download: download})
          :error -> state
        end

      :none ->
        state
    end
  end

  defp next_assignment(state) do
    idle = idle_peers(state)
    pick(state, idle, rarity_counts(state, idle), [])
  end

  defp pick(state, idle, counts, excluded) do
    case DownloadState.assign(state.download, counts) do
      {:ok, index, download} ->
        cond do
          index in excluded ->
            :none

          peer = find_holder(idle, index, state) ->
            {:ok, peer, index, download}

          true ->
            pick(state, idle, Map.put(counts, index, 0), [index | excluded])
        end

      {:error, _} ->
        :none
    end
  end

  defp idle_peers(state) do
    busy =
      state.workers
      |> Map.values()
      |> Enum.map(fn %{peer: peer} -> peer_key(peer) end)
      |> MapSet.new()

    Enum.reject(state.peers, fn peer ->
      MapSet.member?(busy, peer_key(peer)) or MapSet.member?(state.skipped, peer_key(peer))
    end)
  end

  # Eligible holders among idle peers: not known-missing, and either
  # reported holding the piece or not yet reported (optimistic).
  defp rarity_counts(state, idle) do
    for index <- DownloadState.needed(state.download), into: %{} do
      {index, Enum.count(idle, &eligible?(&1, index, state))}
    end
  end

  defp eligible?(peer, index, state) do
    key = peer_key(peer)

    not MapSet.member?(Map.get(state.missing, key, MapSet.new()), index) and
      (not Map.has_key?(state.availability, key) or
         MapSet.member?(state.availability[key], index))
  end

  # Prefer reported holders over optimistic unknowns; both peer-ordered.
  defp find_holder(idle, index, state) do
    {reported, unreported} =
      idle
      |> Enum.filter(&eligible?(&1, index, state))
      |> Enum.split_with(&Map.has_key?(state.availability, peer_key(&1)))

    List.first(reported ++ unreported)
  end

  defp start_worker(state, peer, index) do
    opts = [
      peer: peer,
      info_hash: state.info_hash,
      peer_id: state.peer_id,
      info: state.info,
      piece_index: index,
      piece_hash: Enum.at(state.piece_hashes, index),
      base_dir: state.base_dir,
      network: state.network,
      disk: state.disk,
      sock: state.sock,
      clock: state.clock,
      recv_timeout: state.recv_timeout,
      piece_timeout: state.piece_timeout,
      max_inflight: state.max_inflight,
      report_to: self()
    ]

    case safe_start_child(state.sup, {PeerWorker, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, put_in(state.workers[pid], %{peer: peer, index: index, ref: ref})}

      {:error, reason} ->
        Logger.warning("Coordinator could not start worker: #{inspect(reason)}")
        :error
    end
  end

  # The peer supervisor may be mid-restart (one-for-one sibling); a
  # failed start is retried on the next trigger, never a crash.
  defp safe_start_child(sup, child) do
    DynamicSupervisor.start_child(sup, child)
  catch
    :exit, reason -> {:error, reason}
  end

  # -- exit handling -----------------------------------------------------------

  defp verified?(state, index), do: MapSet.member?(state.download.verified, index)

  defp complete_piece(state, index) do
    %{state | download: DownloadState.complete(state.download, index)}
  end

  defp fail_assignment(state, peer, index, :normal) do
    # A :normal exit for an unverified piece means the peer lacks it:
    # verified exits never reach here (the caller forgets them above),
    # so this always records missing and requeues.
    state = %{state | download: DownloadState.requeue(state.download, index)}

    %{
      state
      | missing:
          Map.update(state.missing, peer_key(peer), MapSet.new([index]), &MapSet.put(&1, index))
    }
  end

  defp fail_assignment(state, peer, index, _reason) do
    failures = Map.update(state.failures, peer_key(peer), 1, &(&1 + 1))
    state = %{state | failures: failures, download: DownloadState.requeue(state.download, index)}

    if Map.fetch!(failures, peer_key(peer)) >= state.max_peer_failures do
      Logger.warning("Skipping peer #{inspect(peer_key(peer))} after repeated failures")
      if state.report_to, do: send(state.report_to, {:peer_skipped, peer_key(peer)})

      %{state | skipped: MapSet.put(state.skipped, peer_key(peer))}
    else
      state
    end
  end

  defp forget_failure(state, peer) do
    %{state | failures: Map.delete(state.failures, peer_key(peer))}
  end

  defp cancel_duplicates(state, index) do
    for {pid, %{index: ^index}} <- state.workers, do: send(pid, {:cancel_piece, index})
    :ok
  end

  defp note_progress(state) do
    %{
      state
      | download: DownloadState.note_progress(state.download, state.clock.monotonic_ms()),
        stall_count: 0
    }
  end

  # -- watchdog ------------------------------------------------------------------

  defp schedule_watchdog(state) do
    Process.send_after(self(), :watchdog_check, state.watchdog_timeout)
    :ok
  end

  defp check_watchdog(state, now) do
    if DownloadState.stalled?(state.download, now, state.watchdog_timeout) do
      handle_stall(state, now)
    else
      state
    end
  end

  defp handle_stall(state, now) do
    stall_count = state.stall_count + 1

    if stall_count > state.max_stalls do
      Logger.warning("Download stalled with no progress; giving up")

      if state.report_to, do: send(state.report_to, {:download_stalled, state.info_hash})
      {:stop, :normal, %{state | stall_count: stall_count}}
    else
      Logger.warning("Download stalled; restarting workers (#{stall_count})")
      state = restart_workers(%{state | stall_count: stall_count})
      %{state | download: DownloadState.note_progress(state.download, now)}
    end
  end

  defp restart_workers(state) do
    pids = Map.keys(state.workers)

    download =
      Enum.reduce(pids, state.download, fn pid, download ->
        DownloadState.requeue(download, state.workers[pid].index)
      end)

    for pid <- pids, do: stop_worker(state, pid)
    try_assign(%{state | download: download, workers: %{}})
  end

  defp stop_worker(state, pid) do
    # Callers only pass live, mapped workers (restart sweeps the map
    # snapshot with no interleaving), so a miss is a bug, not a case.
    {:ok, %{ref: ref}} = Map.fetch(state.workers, pid)
    Process.demonitor(ref, [:flush])

    try do
      DynamicSupervisor.terminate_child(state.sup, pid)
    catch
      _, _ -> {:error, :noproc}
    end

    :ok
  end

  # -- orphans ---------------------------------------------------------------------

  # The peer supervisor restarts abnormal exits with the same piece; those
  # restarts are invisible to the coordinator, so terminate any child it
  # did not start. Their completion messages still count if they win the
  # race. Never raises: a dead supervisor just means nothing to reap.
  defp reap_orphans(state) do
    known = MapSet.new(Map.keys(state.workers))

    try do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(state.sup),
          is_pid(pid),
          not MapSet.member?(known, pid) do
        DynamicSupervisor.terminate_child(state.sup, pid)
      end
    catch
      # A dead supervisor exits the call; a malformed one should crash.
      _, _ -> :ok
    end

    :ok
  end

  defp peer_key(%Peer{ip_tuple: ip, port: port}), do: {ip, port}

  defp clock(opts), do: Keyword.get(opts, :clock, TorrentClient.Clock)
end
