defmodule TorrentClient.Session do
  @moduledoc """
  Multi-torrent session: the singleton above the per-torrent subtrees.

  Owns the listen port (picked once at startup, never at compile time),
  one stable peer id for every torrent (trackers see no flapping
  identities), and the table of torrents by raw info-hash. Each torrent
  runs as a `TorrentSupervisor` child of the session supervisor; the
  session starts it, stops it on pause, and restarts it on resume with
  the persisted verified set.

  Torrent files are the trust boundary: `add_torrent/3` parses, hashes,
  lays out, and announce-fetches before anything starts. Resume bytes are
  distrusted on load — identity (hash, total, piece length) must match the
  torrent or the verified set is dropped. Addressing is exact hex id
  first, unique id prefix second, torrent path third.

  Terminal reports from a torrent's coordinator stop the subtree and set
  the entry's status; give-up reports also carry the verified/total
  progress the attempt published, so an exhausted entry (and `status/1`)
  shows what survived a crash.
  """

  use GenServer

  require Logger

  alias TorrentClient.{Announcer, Config, Disk, TorrentSupervisor}

  @type torrent_id :: String.t()
  @type status :: :downloading | :paused | :complete | :stalled | :exhausted

  @doc """
  Start the session. Opts: `:name` (default `TorrentClient.Session`),
  `:port` (explicit wins), `:config_path` (port fallback), `:disk`,
  `:udp`, `:supervisor` (default `TorrentClient.SessionSupervisor`),
  `:announce_timeout` ms (default 10 000), plus coordinator pass-throughs
  (`:max_peers`, `:max_inflight`, `:recv_timeout`, `:piece_timeout`,
  `:watchdog_timeout`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a torrent file. Returns `{:ok, hex_id}`."
  @spec add_torrent(Path.t(), keyword(), GenServer.server()) ::
          {:ok, torrent_id()} | {:error, term()}
  def add_torrent(path, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:add, path, opts}, 60_000)
  end

  @doc "Stop a torrent's subtree, keeping its state for resume."
  @spec pause(String.t(), GenServer.server()) :: {:ok, torrent_id()} | {:error, term()}
  def pause(id_or_path, server \\ __MODULE__) do
    GenServer.call(server, {:pause, id_or_path})
  end

  @doc "Start a paused, stalled, or exhausted torrent back with its resume state."
  @spec resume(String.t(), GenServer.server()) :: {:ok, torrent_id()} | {:error, term()}
  def resume(id_or_path, server \\ __MODULE__) do
    GenServer.call(server, {:resume, id_or_path})
  end

  @doc "Forget a torrent: stop its subtree and drop the entry (data on disk stays)."
  @spec forget(String.t(), GenServer.server()) :: {:ok, torrent_id()} | {:error, term()}
  def forget(id_or_path, server \\ __MODULE__) do
    GenServer.call(server, {:forget, id_or_path})
  end

  @doc """
  Drop a torrent: stop its subtree, delete its layout files plus resume
  state, forget the entry. Only layout-owned files go; parent directories
  (possibly shared) survive. `dry_run: true` lists targets, deletes nothing.
  """
  @spec remove(String.t(), keyword(), GenServer.server()) ::
          {:ok, torrent_id(), [Path.t()]} | {:error, term()}
  def remove(id_or_path, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:remove, id_or_path, opts})
  end

  @doc "Every known torrent: id, path, download dir, lifecycle status, and last published progress."
  @spec status(GenServer.server()) :: [
          %{
            id: torrent_id(),
            path: Path.t(),
            base_dir: Path.t(),
            status: status(),
            verified: non_neg_integer(),
            total: non_neg_integer()
          }
        ]
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "The listen port picked at startup."
  @spec port(GenServer.server()) :: pos_integer()
  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  # -- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    port = resolve_port(opts)
    Logger.debug("session starting on port #{port}")

    {:ok,
     %{
       port: port,
       peer_id: Utils.generate_peer_id(),
       torrents: %{},
       disk: Keyword.get(opts, :disk, Disk),
       udp: Keyword.get(opts, :udp, TorrentClient.Udp),
       supervisor: Keyword.get(opts, :supervisor, TorrentClient.SessionSupervisor),
       announce_timeout: Keyword.get(opts, :announce_timeout, 10_000),
       coord_opts:
         Keyword.take(opts, [
           :max_peers,
           :max_inflight,
           :recv_timeout,
           :piece_timeout,
           :watchdog_timeout,
           :webseed_http
         ])
     }}
  end

  @impl true
  def handle_call({:add, path, opts}, _from, state) do
    case start_torrent(state, path, opts) do
      {:ok, id, state} ->
        Logger.info("added #{id} #{path}")
        {:reply, {:ok, id}, state}

      {:error, _} = err ->
        Logger.error("add failed #{path}: #{inspect(err)}")
        {:reply, err, state}
    end
  end

  def handle_call({:pause, id_or_path}, _from, state) do
    case find(state, id_or_path) do
      {:ok, raw, entry} ->
        state = pause_entry(state, raw, entry)
        Logger.info("paused #{entry.id}")
        {:reply, {:ok, entry.id}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:resume, id_or_path}, _from, state) do
    case find(state, id_or_path) do
      {:ok, raw, entry} ->
        case resume_entry(state, raw, entry) do
          {:ok, id, state} ->
            Logger.info("resumed #{id}")
            {:reply, {:ok, id}, state}

          {:error, _} = err ->
            Logger.error("resume failed #{entry.id}: #{inspect(err)}")
            {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:forget, id_or_path}, _from, state) do
    case find(state, id_or_path) do
      {:ok, raw, entry} ->
        stop_sup(state, entry)
        Logger.info("forgot #{entry.id}")
        {:reply, {:ok, entry.id}, %{state | torrents: Map.delete(state.torrents, raw)}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:status, _from, state) do
    entries =
      Enum.map(state.torrents, fn {_raw, entry} ->
        Map.take(entry, [:id, :path, :base_dir, :status, :verified, :total])
      end)

    {:reply, entries, state}
  end

  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call({:remove, id_or_path, opts}, _from, state) do
    case find(state, id_or_path) do
      {:ok, _raw, entry} ->
        case remove_entry(state, entry, opts) do
          {:ok, files, state} -> {:reply, {:ok, entry.id, files}, state}
          {:error, _} = err -> {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_info({report, raw, progress}, state)
      when report in [:torrent_complete, :swarm_exhausted, :download_stalled] do
    handle_report(state, raw, report, progress)
  end

  # Older/other senders report bare tuples: keep them working, just
  # without progress (the entry keeps whatever it published before).
  def handle_info({report, raw}, state)
      when report in [:torrent_complete, :swarm_exhausted, :download_stalled] do
    handle_report(state, raw, report, nil)
  end

  def handle_info({:peer_skipped, _peer}, state) do
    {:noreply, state}
  end

  defp handle_report(state, raw, report, progress) do
    status =
      case report do
        :torrent_complete -> :complete
        :swarm_exhausted -> :exhausted
        :download_stalled -> :stalled
      end

    case Map.fetch(state.torrents, raw) do
      {:ok, entry} ->
        # The coordinator is gone but its supervisor (and peer workers)
        # lingers: stop the subtree so the Registry names free up for
        # resume and nothing keeps dialing after the terminal report.
        stop_sup(state, entry)

        case report do
          :torrent_complete -> Logger.info("Torrent #{entry.id} complete")
          _ -> Logger.warning("Torrent #{entry.id} #{report}")
        end

        entry = publish_progress(entry, report, progress)

        {:noreply,
         %{state | torrents: Map.put(state.torrents, raw, %{entry | status: status, sup: nil})}}

      :error ->
        {:noreply, state}
    end
  end

  # Keep the progress the crashed attempt published: a give-up report
  # carries its verified/total so an exhausted entry can show it. A
  # completion implies everything.
  defp publish_progress(entry, :torrent_complete, _progress), do: %{entry | verified: entry.total}

  defp publish_progress(entry, _report, %{verified: verified, total: total}) do
    %{entry | verified: verified, total: total}
  end

  defp publish_progress(entry, _report, _progress), do: entry

  # -- startup -----------------------------------------------------------

  # The configured port is best-effort: bound here means taken, so fall
  # back to a free OS pick rather than colliding or failing to boot.
  defp resolve_port(opts) do
    port = Keyword.get(opts, :port) || configured_port(opts)

    if is_integer(port) and port_free?(port) do
      port
    else
      if is_integer(port) do
        Logger.warning("port #{port} busy, falling back to a free pick")
      end

      Utils.get_port()
    end
  end

  defp configured_port(opts) do
    case Keyword.get(opts, :config_path) do
      nil -> nil
      path -> with {:ok, %{port: port}} <- Config.load(path), do: port
    end
  end

  defp port_free?(port) do
    case :gen_tcp.listen(port, []) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  # -- torrents ----------------------------------------------------------

  defp start_torrent(state, path, opts) do
    with {:ok, bytes} <- state.disk.read(path),
         {:ok, bento, raw_info} <- Torrent.parse_bytes(bytes),
         hex = Torrent.info_hash(raw_info),
         raw = Base.decode16!(hex),
         :ok <- check_new(state, raw),
         hashes when is_list(hashes) <- Torrent.get_piece_hashes(bento),
         base_dir = Keyword.get(opts, :base_dir, Path.basename(path, ".torrent")),
         :ok <- state.disk.init_layout(base_dir, bento.info) do
      verified =
        Disk.load_verified(state.disk, base_dir, %{
          info_hash: raw,
          total: length(hashes),
          piece_length: piece_length(bento.info)
        })

      static_peers = Keyword.get(opts, :peers)

      entry = %{
        id: hex,
        raw: raw,
        path: path,
        base_dir: base_dir,
        info: bento.info,
        bento: bento,
        peers: static_peers,
        webseed_urls: Torrent.url_list(bytes),
        announce_timeout: Keyword.get(opts, :announce_timeout, state.announce_timeout),
        sup: nil,
        status: :downloading,
        verified: length(verified),
        total: length(hashes)
      }

      if length(verified) == length(hashes) do
        {:ok, hex, put_in(state.torrents[raw], %{entry | status: :complete})}
      else
        peers = static_peers || announce_peers(state, entry)
        start_subtree(state, entry, %{hashes: hashes, peers: peers, verified: verified})
      end
    end
  end

  # No peers anywhere (static or announced) and no webseed URLs is not
  # a failed add: the entry waits exhausted until resume re-announces
  # into a live swarm. Webseeds alone still start a coordinator.
  defp start_subtree(state, %{webseed_urls: []} = entry, %{peers: []}) do
    {:ok, entry.id, put_in(state.torrents[entry.raw], %{entry | status: :exhausted})}
  end

  defp start_subtree(state, entry, torrent) do
    coord_opts =
      state.coord_opts ++
        [
          info_hash: entry.raw,
          info: entry.info,
          piece_hashes: torrent.hashes,
          base_dir: entry.base_dir,
          peer_id: state.peer_id,
          peers: torrent.peers,
          verified: torrent.verified,
          report_to: self(),
          webseed_urls: entry.webseed_urls,
          refill_peers: refill_fun(state, entry)
        ]

    # A dead supervisor exits the call; translate it so the session
    # survives to report the failure instead of crashing with it.
    case try_start_child(state.supervisor, coord_opts) do
      {:ok, sup} ->
        {:ok, entry.id, put_in(state.torrents[entry.raw], %{entry | sup: sup})}

      {:error, _} = err ->
        Logger.error("subtree start failed #{entry.id}: #{inspect(err)}")
        err
    end
  end

  defp try_start_child(supervisor, coord_opts) do
    DynamicSupervisor.start_child(supervisor, {TorrentSupervisor, coord_opts})
  catch
    :exit, reason -> {:error, reason}
  end

  defp check_new(state, raw) do
    if Map.has_key?(state.torrents, raw), do: {:error, :already_added}, else: :ok
  end

  # Atom keys from bento structs, string keys from raw info maps (tests,
  # fixtures); both flow through here, so accept either.
  defp piece_length(info) do
    Map.get(info, :"piece length") || Map.get(info, "piece length")
  end

  defp announce_peers(state, entry) do
    urls = entry.bento |> Torrent.announce_tiers() |> List.flatten()
    announce(state, entry, urls)
  end

  defp refill_fun(state, entry) do
    urls = entry.bento |> Torrent.announce_tiers() |> List.flatten()
    fn -> announce(state, entry, urls) end
  end

  defp announce(state, entry, urls) do
    timeout = entry.announce_timeout

    query = fn url ->
      # Logged before the call so blackholed trackers show up as
      # pending queries, not silence, when the fan-out times out.
      Logger.debug("querying tracker #{url}")

      outcome =
        Announcer.query_once(url,
          bento: entry.bento,
          info_hash: entry.id,
          peer_id: state.peer_id,
          port: state.port,
          udp: state.udp
        )

      Logger.debug("tracker #{url}: #{inspect(outcome |> announce_summary())}")
      outcome
    end

    case Announcer.announce_all(urls, query, timeout: timeout) do
      {:ok, %{peers: peers}} ->
        Logger.debug("announce for #{entry.id}: #{length(peers)} peers")
        peers

      {:error, _} ->
        []
    end
  end

  defp announce_summary({:ok, %{peers: peers}}), do: "#{length(peers)} peers"
  defp announce_summary({:error, reason}), do: "failed: #{inspect(reason)}"

  # -- lifecycle ---------------------------------------------------------

  # Pausing a complete torrent is a no-op: there is nothing to stop,
  # and flipping it to :paused would lie in status until resume.
  defp pause_entry(state, _raw, %{status: :complete}) do
    state
  end

  defp pause_entry(state, raw, %{sup: nil} = entry) do
    put_in(state.torrents[raw], %{entry | status: :paused})
  end

  defp pause_entry(state, raw, entry) do
    stop_sup(state, entry)
    put_in(state.torrents[raw], %{entry | status: :paused, sup: nil})
  end

  defp resume_entry(_state, _raw, %{status: :downloading}) do
    {:error, :already_running}
  end

  defp resume_entry(state, _raw, %{status: :complete} = entry) do
    {:ok, entry.id, state}
  end

  defp resume_entry(state, raw, entry) do
    # Restart through the normal path so resume bytes reload; drop the
    # stale entry first so the new one replaces it. Static peers and the
    # announce timeout carry over, otherwise the swarm is re-announced
    # with different knobs.
    state = %{state | torrents: Map.delete(state.torrents, raw)}

    opts =
      [base_dir: entry.base_dir, announce_timeout: entry.announce_timeout] ++
        if(entry.peers, do: [peers: entry.peers], else: [])

    case start_torrent(state, entry.path, opts) do
      {:ok, _id, state} -> {:ok, entry.id, state}
      {:error, _} = err -> err
    end
  end

  # Validate every target before deleting any: a path that no longer
  # resolves inside the download dir aborts the whole removal.
  defp remove_entry(state, entry, opts) do
    case layout_files(entry.base_dir, entry.info) do
      {:ok, files} ->
        targets = [Disk.resume_path(entry.base_dir) | files]
        delete_targets(state, entry, targets, opts)

      {:error, _} = err ->
        Logger.error("remove failed #{entry.id}: #{inspect(err)}")
        err
    end
  end

  defp delete_targets(state, entry, targets, opts) do
    if Keyword.get(opts, :dry_run, false) do
      {:ok, targets, state}
    else
      stop_sup(state, entry)
      Enum.each(targets, &delete_path(state, &1))
      Logger.info("removed #{entry.id} (#{length(targets)} files)")
      {:ok, targets, %{state | torrents: Map.delete(state.torrents, entry.raw)}}
    end
  end

  defp layout_files(base_dir, info) do
    with {:ok, entries} <- Torrent.layout(info) do
      base = Path.expand(base_dir)
      paths = Enum.map(entries, &Path.expand(Path.join(base, &1.path)))

      if Enum.all?(paths, &inside?(base, &1)) do
        {:ok, paths}
      else
        {:error, :path_escape}
      end
    end
  end

  defp inside?(base, path), do: path == base or String.starts_with?(path, base <> "/")

  defp delete_path(state, path) do
    case state.disk.delete(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Could not delete #{path}: #{inspect(reason)}")
    end
  end

  defp stop_sup(_state, %{sup: nil}), do: :ok

  # The supervisor may die under us (its own shutdown); a failing
  # terminate is not a failed pause. The call must sit inside the try:
  # wrapping it in a helper catches nothing (args evaluate first).
  defp stop_sup(state, %{sup: sup}) do
    try do
      DynamicSupervisor.terminate_child(state.supervisor, sup)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # Unique id prefix first (a full id is its own unique prefix), then
  # torrent path. Registry keys are raw bytes, so callers never hit an
  # exact-key match — prefix subsumes it.
  defp find(state, id_or_path) do
    cond do
      matching = prefix_match(state, id_or_path) ->
        {:ok, matching.raw, matching}

      matching = path_match(state, id_or_path) ->
        {:ok, matching.raw, matching}

      true ->
        {:error, :not_found}
    end
  end

  defp prefix_match(state, prefix) when is_binary(prefix) do
    case Enum.filter(state.torrents, fn {raw, _} -> String.starts_with?(hex(raw), prefix) end) do
      [{_raw, entry}] -> entry
      _ -> nil
    end
  end

  defp prefix_match(_state, _prefix), do: nil

  defp path_match(state, path) do
    case Enum.filter(state.torrents, fn {_raw, entry} -> entry.path == path end) do
      [{_raw, entry}] -> entry
      _ -> nil
    end
  end

  defp hex(raw), do: Base.encode16(raw)
end
