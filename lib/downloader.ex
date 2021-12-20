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
  def handle_cast({:filter_peers, :connected}, state) do
    connected_peers =
      Enum.filter(state.peers, fn peer ->
        case Client.connect(peer) do
          {:ok, _} ->
            IO.puts("Peer: " <> peer.ip <> " is connected")
            true

          {:error, _} ->
            IO.puts("ERROR Unable to connect to Peer: #{peer.ip}")

            false
        end
      end)

    {:noreply, %{state | peers: connected_peers}}
  end

  @impl true
  def handle_call(:report, _from, state) do
    # _from is the client calling this function
    # should return a tuple: {:reply, response, state}
    {:reply, state, state}
  end

  @doc """
  Instruct the server to filter out the unresponsive peers
  """
  def filter_connected_peers(server) do
    GenServer.cast(server, {:filter_peers, :connected})
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

  def test_file do
    "test/_data/debian-10.2.0-amd64-netinst.iso.torrent"
  end

  def sample_torrent() do
    test_file()
    |> to_bento_torrent()
    |> Torrent.from_bento(%{peer_id: @peer_id})
  end

  def tracker_peers(torrent \\ sample_torrent()) do
    torrent |> Tracker.peers(@peer_id, @port)
  end

  def random_peer(torrent \\ sample_torrent()) do
    torrent |> tracker_peers() |> Enum.random()
  end

  def connect_to_random_peer(torrent \\ sample_torrent()) do
    {:ok, server} = start_link(torrent)
    filter_connected_peers(server)

    # TODO: Call this after some time
    # OR have GenServer tell us when the filtering is complete
    state = report(server)
    connected_peers = Enum.count(state.peers)
    IO.puts("Connected peers: #{connected_peers}")
  end
end
