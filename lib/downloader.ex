defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

  require Logger
  use GenServer

  @init_state %{
    port: 6882,
    peer_id: Utils.generate_peer_id()
  }

  def start_link(torrent_filename) do
    GenServer.start_link(__MODULE__, torrent_filename, name: __MODULE__)
  end

  @doc """
  Stop the server
  """
  def stop(server) do
    GenServer.cast(server, :stop)
  end

  # @doc """
  # Instruct the server to connect to the peers
  # """

  def connect_peers(server) do
    GenServer.cast(server, :connect_peers)
  end

  # @doc """
  # Instruct the server to complete a handshake with peers
  # """

  # def handshake_peer_clients(server) do
  #   GenServer.cast(server, {:filter_peers, :handshake})
  # end

  # @doc """
  # Instruct the server to only keep processes that are still alive
  # """
  # def filter_alive_peers(server) do
  #   GenServer.cast(server, {:filter_peers, :alive})
  # end

  @doc """
  Invoked when the server is started.
  start_link/3 will block until it returns.
  """
  @impl true
  def init(torrent_filename) do
    case parse_torrent_file(torrent_filename) do
      {:ok, bento_torrent} ->
        state =
          @init_state
          |> Map.put(:filename, torrent_filename)
          |> Map.put(:bento_torrent, bento_torrent)

        {:ok, state, {:continue, :fetch_peers}}

      {:error, _} ->
        {:stop, :shutdown}
    end
  end

  @impl true
  def handle_continue(
        :fetch_peers,
        %{bento_torrent: bento_torrent, peer_id: peer_id, port: port} = state
      ) do
    tracker_url = Tracker.tracker_url(bento_torrent, peer_id, port)

    case Tracker.get_peers(tracker_url) do
      # TODO: also match on the interval and store it
      {:ok, %{peers: peers}} ->
        Logger.info("Found Peers: #{Enum.count(peers)}")
        # TODO: Start the peer connections here
        {:noreply, Map.put(state, :peers, peers)}

      {:error, reason} ->
        Logger.error("Get Peers Error: #{reason}")
        {:noreply, Map.put(state, :peers, [])}
    end
  end

  @impl true
  def handle_cast(
        :connect_peers,
        %{peers: peers, peer_id: peer_id, bento_torrent: bento_torrent} = state
      ) do
    peers_with_pids =
      peers
      |> Enum.map(fn peer ->
        case Client.start_link(self(), bento_torrent, peer, peer_id) do
          {:ok, pid} ->
            # TODO: Maybe these are the only peers that should be added to the state?
            Logger.info("Connected Peer: #{peer.ip_tuple}")
            %{peer | pid: pid}

          :ignore ->
            peer

          {:error, _} ->
            peer
        end
      end)

    # Logger.info("peers_with_pids: #{peers_with_pids}")
    # |> Enum.reject(fn peer -> is_nil(peer.pid) end)

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

  def parse_torrent_file(filename) do
    with {:ok, file_contents} <- File.read(filename),
         {:ok, parsed_torrent} <- Bento.torrent(file_contents) do
      {:ok, parsed_torrent}
    end
  end

  def test_run() do
    # Start the server
    {:ok, pid} = start_link(Utils.single_file_torrent())

    # connect_peers(server)

    # TODO: Call this after some time
    # OR have GenServer tell us when the filtering is complete
    state = :sys.get_state(pid)
    connected_peers = Enum.count(state.peers)
    Logger.debug("Connected peers: #{connected_peers}")
  end
end
