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
    tracker_url =
      Tracker.tracker_url(bento_torrent.announce, bento_torrent, info_hash, peer_id, port)

    case RequestsClient.get_peers(tracker_url) do
      {:ok, %{peers: peers, interval: interval}} ->
        Logger.info("Found Peers: #{Enum.count(peers)}")
        {:noreply, state |> Map.put(:peers, peers) |> Map.put(:interval, interval)}

      {:error, reason} ->
        Logger.error("Get Peers Error: #{reason}")
        {:noreply, Map.put(state, :peers, [])}
    end
  end

  # Peer wiring moved to TorrentClient.PeerSupervisor + PeerWorker (kog.8);
  # the per-torrent coordinator owns worker startup (kog.9).
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
