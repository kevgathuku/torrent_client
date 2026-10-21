defmodule TorrentClient.Announcer do
  @moduledoc """
  Interval-driven re-announce worker. Walks announce tiers in order (UDP via
  the injected transport, HTTP via the requests seam), failing over on
  error and re-announcing every interval. Supervised: crash restarts it,
  state rebuilds from the next cycle.

  `announce_all/3` is the bounded whole-announce: every tracker queried
  concurrently, peers merged as answers land, resolving within the timeout
  even when trackers black-hole. Used for initial peer acquisition; the
  supervised cycle keeps the sequential tier walk.
  """

  use GenServer
  require Logger

  alias TorrentClient.{Backoff, TierState, UdpTracker}
  alias TorrentClient.Requests.Client, as: RequestsClient

  @impl true
  def start_link(opts) do
    tiers =
      case Keyword.get(opts, :tracker_url) do
        nil ->
          opts |> Keyword.fetch!(:bento) |> Torrent.announce_tiers() |> shuffle_tiers()

        url ->
          [[url]]
      end

    state = %{
      bento: Keyword.fetch!(opts, :bento),
      info_hash: Keyword.fetch!(opts, :info_hash),
      peer_id: Keyword.fetch!(opts, :peer_id),
      port: Keyword.fetch!(opts, :port),
      tiers: tiers,
      tier_state: TierState.new(tiers),
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      udp: Keyword.get(opts, :udp, TorrentClient.Udp),
      key: :rand.uniform(0xFFFFFFFF),
      peers: [],
      failures: 0,
      started: false
    }

    name_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, state, name_opts)
  end

  @impl true
  def init(state) do
    send(self(), :announce)
    {:ok, state}
  end

  @impl true
  def handle_info(:announce, state) do
    {state, delay} = cycle(state)
    Process.send_after(self(), :announce, delay)
    {:noreply, state}
  end

  defp cycle(state) do
    case TierState.next(state.tier_state) do
      {:error, :exhausted} ->
        delay = Backoff.delay(state.failures, state.interval_ms, state.interval_ms * 8)
        state = %{state | tier_state: TierState.new(state.tiers), failures: state.failures + 1}
        {state, delay}

      {:ok, url, tier_state} ->
        state = %{state | tier_state: tier_state}

        case announce(state, url) do
          {:ok, %{peers: peers, interval: interval}} ->
            {:ok, tier_state} = TierState.report(tier_state, :ok, url)

            {%{
               state
               | tier_state: tier_state,
                 peers: peers,
                 started: true,
                 failures: 0
             }, max(state.interval_ms, interval * 1_000)}

          {:error, _} ->
            {:ok, tier_state} = TierState.report(tier_state, :error, url)
            cycle(%{state | tier_state: tier_state})
        end
    end
  end

  defp announce(state, url) do
    case URI.parse(url).scheme do
      "udp" -> udp_announce(state, url)
      scheme when scheme in ["http", "https"] -> http_announce(state, url)
      _ -> {:error, :unsupported_scheme}
    end
  end

  defp udp_announce(state, url) do
    %{host: host, port: port} = URI.parse(url)

    with xid <- :rand.uniform(0xFFFFFFFF),
         {:ok, connect_req} <- UdpTracker.encode_connect(xid),
         {:ok, %{data: connect_resp}} <- state.udp.send_recv(host, port, connect_req, 5_000),
         {:ok, %{connection_id: conn}} <- UdpTracker.decode_connect(connect_resp, xid),
         axid <- :rand.uniform(0xFFFFFFFF),
         {:ok, announce_req} <- UdpTracker.encode_announce(announce_params(state, conn, axid)),
         {:ok, %{family: family, data: announce_resp}} <-
           state.udp.send_recv(host, port, announce_req, 5_000),
         {:ok, %{peers: raw_peers, interval: interval}} <-
           UdpTracker.decode_announce(announce_resp, axid, ip_version(family)),
         {:ok, peers} <- Peer.parse_compact(raw_peers, ip_version(family)) do
      {:ok, %{peers: peers, interval: interval}}
    end
  end

  defp ip_version(:inet), do: :ipv4
  defp ip_version(:inet6), do: :ipv6

  defp announce_params(state, connection_id, transaction_id) do
    %{
      connection_id: connection_id,
      transaction_id: transaction_id,
      info_hash: Base.decode16!(state.info_hash),
      peer_id: state.peer_id,
      downloaded: 0,
      left: Torrent.remaining(state.bento),
      uploaded: 0,
      event: if(state.started, do: 0, else: 2),
      ip: 0,
      key: state.key,
      num_want: -1,
      port: state.port
    }
  end

  defp http_announce(state, url) do
    full_url =
      Tracker.tracker_url(url, state.bento, state.info_hash, state.peer_id, state.port,
        event: if(state.started, do: nil, else: "started"),
        key: Integer.to_string(state.key)
      )

    case RequestsClient.get_peers(full_url) do
      {:ok, %{peers: _} = response} -> {:ok, response}
      {:error, _} = error -> error
    end
  end

  defp shuffle_tiers(tiers), do: Enum.map(tiers, &Enum.shuffle/1)

  @doc """
  Query every tracker concurrently and merge peers as answers land.

  `query` maps a URL to `{:ok, %{peers: [...], interval: seconds}}` or
  `{:error, reason}`; a query that raises counts as a failed tracker.
  Maximum coverage: one success never stops the rest, errors and timeouts
  are skipped, peers dedupe by address. The call resolves within roughly
  `ceil(n / max_concurrency) * timeout` even when every tracker is
  black-holed — late answers are dropped, not waited on.
  """
  @spec announce_all([String.t()], (String.t() -> {:ok, map()} | {:error, term()}), keyword()) ::
          {:ok, %{peers: [map()], interval: non_neg_integer() | nil}} | {:error, :no_trackers}
  def announce_all([], _query, _opts), do: {:error, :no_trackers}

  def announce_all(urls, query, opts \\ [])
      when is_list(urls) and is_function(query, 1) and is_list(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 8)
    timeout = Keyword.get(opts, :timeout, 15_000)

    urls
    |> Task.async_stream(safe(query),
      max_concurrency: max_concurrency,
      timeout: timeout,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{peers: [], intervals: []}, &merge_answer/2)
    |> finalize()
  end

  # A raising query must fail like any dead tracker, not take the caller
  # down with it. Only exceptions are caught: timeout kills and exits
  # still propagate.
  defp safe(query) do
    fn url ->
      try do
        query.(url)
      rescue
        _ -> {:error, :query_failed}
      end
    end
  end

  defp merge_answer({:ok, {:ok, %{peers: peers, interval: interval}}}, acc) do
    %{acc | peers: acc.peers ++ peers, intervals: [interval | acc.intervals]}
  end

  defp merge_answer(_failed, acc), do: acc

  defp finalize(%{peers: peers, intervals: []}), do: {:ok, %{peers: dedupe(peers), interval: nil}}

  defp finalize(%{peers: peers, intervals: intervals}) do
    {:ok, %{peers: dedupe(peers), interval: Enum.min(intervals)}}
  end

  defp dedupe(peers), do: Enum.uniq_by(peers, &{&1.ip_tuple, &1.port})
end
