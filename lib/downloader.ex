defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

  require Logger
  use GenServer

  @port 6882
  @peer_id Utils.generate_peer_id()

  def start_link(torrent_filename) do
    GenServer.start_link(__MODULE__, torrent_filename, name: __MODULE__)
  end

  @doc """
  Instruct the server to fetch the peers
  """
  def fetch_peers(server) do
    GenServer.cast(server, :fetch_peers)
  end

  @doc """
  Instruct the server to connect to the peers
  """
  def start_peer_clients(server) do
    GenServer.cast(server, :start_peer_clients)
  end

  @doc """
  Instruct the server to complete a handshake with peers
  """
  def handshake_peer_clients(server) do
    GenServer.cast(server, {:filter_peers, :handshake})
  end

  @doc """
  Instruct the server to only keep processes that are still alive
  """
  def filter_alive_peers(server) do
    GenServer.cast(server, {:filter_peers, :alive})
  end

  @doc """
  Instruct the server to report the current GenServer state
  """
  def report(server) do
    GenServer.call(server, :report)
  end

  @doc """
  Stop the server
  """
  def stop(server) do
    GenServer.cast(server, :stop)
  end

  @doc """
  Invoked when the server is started.
  start_link/3 will block until it returns.
  """
  @impl true
  def init(torrent_filename) do
    bento_torrent = parse_torrent_file(torrent_filename)

    state =
      %{}
      |> Map.put(:peer_id, @peer_id)
      |> Map.put(:port, @port)
      |> Map.put(:filename, torrent_filename)
      |> Map.put(:bento_torrent, bento_torrent)

    {:ok, state}
  end

  @impl true
  def handle_cast(:fetch_peers, %{bento_torrent: bento_torrent, peer_id: peer_id, port: port} = state) do
    case tracker_peers(bento_torrent, peer_id, port) do
      [] ->
        Logger.error("ERROR: No peers found")
        {:noreply, Map.put(state, :peers, [])}

      peers ->
        Logger.info("Found Peers: #{Enum.count(peers)}")
        {:noreply, Map.put(state, :peers, peers)}
    end
  end

  @impl true
  def handle_cast(
        :start_peer_clients,
        %{peers: peers, peer_id: peer_id, own_torrent: own_torrent} = state
      ) do
    peers_with_pids =
      peers
      |> Enum.map(fn peer ->
        case Client.start_link(own_torrent, peer, peer_id) do
          {:ok, pid} ->
            %{peer | pid: pid}

          :ignore ->
            peer

          {:error, _} ->
            peer
        end
      end)
      |> Enum.reject(fn peer -> is_nil(peer.pid) end)

    Logger.debug("Started client process for peers: #{Enum.count(peers_with_pids)}")

    {:noreply, Map.put(state, :peers, peers_with_pids)}
  end

  @impl true
  def handle_cast({:filter_peers, :handshake}, state) do
    state.peers
    |> Enum.each(fn peer -> Client.complete_handshake(peer.pid) end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:filter_peers, :alive}, state) do
    handshaked_peers =
      state.peers
      |> Enum.filter(fn peer -> Process.alive?(peer.pid) end)

    Logger.debug("Handshaked Peers: #{Enum.count(handshaked_peers)}")

    {:noreply, %{state | peers: handshaked_peers}}
  end

  @impl true
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  @impl true
  def handle_call(:report, _from, state) do
    # _from is the client calling this function
    # should return a tuple: {:reply, response, state}
    {:reply, state, state}
  end

  # TODO: Add error handling. No need to proceed if torrent file is wrong
  def parse_torrent_file(filename) do
    File.read!(filename)
    |> Bento.torrent!()
  end

  def tracker_peers(bento_torrent, peer_id, port) do
    case Tracker.get_peers(bento_torrent, peer_id, port) do
      {:ok, peers} ->
        Logger.info("Found Peers: #{Enum.count(peers)}")
        peers

      {:error, reason} ->
        Logger.error("Get Peers Error: #{reason}")
        []
    end
  end

  def test_run() do
    torrent_filename = Utils.single_file_torrent()
    # Start the server
    {:ok, pid} = start_link(torrent_filename)
    # Fetch peers
    fetch_peers(pid)

    # filter_connected_peers(server)

    # TODO: Call this after some time
    # OR have GenServer tell us when the filtering is complete
    state = report(pid)
    connected_peers = Enum.count(state.peers)
    Logger.debug("Connected peers: #{connected_peers}")
  end
end
