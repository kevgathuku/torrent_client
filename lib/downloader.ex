defmodule Downloader do
  @moduledoc """
  Entry point for the Downloader.
  """

  require Logger
  use GenServer

  alias TorrentClient.Requests.Client, as: RequestsClient

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

  # def start_peer_clients(server) do
  #   GenServer.cast(server, :start_peer_clients)
  # end

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
      {:ok, bento_torrent, info} ->
        state =
          @init_state
          |> Map.put(:filename, torrent_filename)
          |> Map.put(:bento_torrent, bento_torrent)
          |> Map.put(:info_hash, Torrent.info_hash(info))

        {:ok, state, {:continue, :fetch_peers}}

      # {:ok, state}

      {:error, _} ->
        {:stop, :shutdown}
    end
  end

  @impl true
  def handle_continue(
        :fetch_peers,
        %{bento_torrent: bento_torrent, info_hash: info_hash, peer_id: peer_id, port: port} =
          state
      ) do
    tracker_url = Tracker.tracker_url(bento_torrent, info_hash, peer_id, port)

    case RequestsClient.get_peers(tracker_url) do
      # TODO: also match on the interval and store it
      {:ok, %{peers: peers}} ->
        Logger.info("Found Peers: #{Enum.count(peers)}")
        {:noreply, Map.put(state, :peers, peers)}

      {:error, reason} ->
        Logger.error("Get Peers Error: #{reason}")
        {:noreply, Map.put(state, :peers, [])}
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
        # TODO: Does the Client need to be started with supervision???
        case Client.start_link(own_torrent, peer, peer_id) do
          {:ok, pid} ->
            # TODO: Maybe these are the only peers that should be added to the state?
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

  def parse_torrent_file(filename) do
    # Double parse of a few KB: structs drop unknown info keys, so the raw
    # string-keyed map comes from a plain decode for hashing.
    with {:ok, file_contents} <- File.read(filename),
         {:ok, parsed_torrent} <- Bento.torrent(file_contents),
         {:ok, decoded} <- Bento.decode(file_contents) do
      case decoded do
        %{"info" => info} when is_map(info) -> {:ok, parsed_torrent, info}
        _ -> {:error, :missing_info}
      end
    end
  end
end
