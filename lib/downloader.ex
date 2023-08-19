defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

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
    bento_torrent = to_bento_torrent(torrent_filename)
    own_torrent = to_own_torrent(bento_torrent)

    state =
      %{}
      |> Map.put(:filename, torrent_filename)
      |> Map.put(:own_torrent, own_torrent)

    {:ok, state}
  end

  @impl true
  def handle_cast(:fetch_peers, %{own_torrent: own_torrent} = state) do
    IO.puts("Inside fetch_peers")
    peers = tracker_peers(own_torrent)

    IO.puts("Found Peers: #{Enum.count(peers)}")

    {:noreply, Map.put(state, :peers, peers)}
  end

  @impl true
  def handle_cast(:start_peer_clients, state) do
    peers_with_pids =
      state.peers
      |> Enum.map(fn peer ->
        case Client.start_link(state.torrent, peer) do
          {:ok, pid} ->
            %{peer | pid: pid}

          :ignore ->
            peer

          {:error, _} ->
            peer
        end
      end)
      |> Enum.reject(fn peer -> is_nil(peer.pid) end)

    IO.puts("Remaining Peers: #{Enum.count(peers_with_pids)}")

    {:noreply, %{state | peers: peers_with_pids}}
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

    IO.puts("Handshaked Peers: #{Enum.count(handshaked_peers)}")

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

  def to_own_torrent(bento_torrent) do
    bento_torrent
    |> Torrent.from_bento()
  end

  def to_bento_torrent(filename) do
    File.read!(filename)
    |> Bento.torrent!()
  end

  def tracker_peers(own_torrent) do
    Tracker.get_peers(own_torrent, @peer_id, @port)
  end

  def test_run() do
    torrent_filename = Utils.test_torrent_file()
    {:ok, server} = start_link(torrent_filename)
    # filter_connected_peers(server)

    # TODO: Call this after some time
    # OR have GenServer tell us when the filtering is complete
    state = report(server)
    connected_peers = Enum.count(state.peers)
    IO.puts("Connected peers: #{connected_peers}")
  end
end
