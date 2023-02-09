defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

  use GenServer

  @port 6882
  @peer_id Utils.generate_peer_id()
  @initial_state %{torrent: nil, peers: nil}

  @impl true
  def init(state) do
    {:ok, state}
  end

  def start_link(torrent) do
    peers = torrent |> tracker_peers()
    state = @initial_state |> Map.put(:torrent, torrent) |> Map.put(:peers, peers)
    GenServer.start_link(__MODULE__, state, name: Downloader)
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
  def handle_call(:report, _from, state) do
    # _from is the client calling this function
    # should return a tuple: {:reply, response, state}
    {:reply, state, state}
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

  def to_bento_torrent(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def debian_torrent_file do
    "test/_data/debian-10.2.0-amd64-netinst.iso.torrent"
  end

  def debian_bento_torrent() do
    debian_torrent_file()
    |> to_bento_torrent()
  end

  def bento_to_torrent(bento_torrent \\ debian_bento_torrent()) do
    bento_torrent |> Torrent.from_bento(%{peer_id: @peer_id})
  end

  def tracker_peers(torrent \\ debian_bento_torrent()) do
    torrent |> Tracker.peers(@peer_id, @port)
  end

  def filter_peers(torrent \\ debian_bento_torrent()) do
    {:ok, server} = start_link(torrent)
    # filter_connected_peers(server)

    # TODO: Call this after some time
    # OR have GenServer tell us when the filtering is complete
    state = report(server)
    connected_peers = Enum.count(state.peers)
    IO.puts("Connected peers: #{connected_peers}")
  end
end
