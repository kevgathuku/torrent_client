defmodule Client do
  @moduledoc """
  Entry point for the Client.
  Connects to a peer
  """

  require Logger

  use GenServer

  @initial_state %{socket: nil, peer: nil, info_hash: nil, peer_id: nil}

  def start_link(torrent, peer) do
    state =
      @initial_state
      |> Map.put(:info_hash, torrent.info_hash)
      |> Map.put(:peer_id, torrent.peer_id)
      |> Map.put(:peer, peer)

    GenServer.start_link(__MODULE__, state)
  end

  @impl true
  def init(init_state) do
    # Initiate connection with peer
    # init_state -> has peer_id, peer and info_hash
    %{peer: peer} = init_state

    case connect(peer) do
      {:ok, socket} ->
        IO.puts("Peer: " <> peer.ip <> " is connected")

        {:ok, %{init_state | socket: socket}}

      {:error, _} ->
        IO.puts("ERROR: Unable to connect to Peer: #{peer.ip}")
        # the process will exit normally without entering the loop
        :ignore
    end
  end

  end

  @impl true
  def handle_call(:report, _from, state) do
    # _from is the client calling this function
    # should return a tuple: {:reply, response, state}
    {:reply, state, state}
  end

  @doc """
  Instruct the server to create a connection to the specified peer
  """
  def connect(peer) do
    Socket.TCP.connect(peer.ip, peer.port, timeout: 3000)
  end

  def send_handshake(socket, info_hash, peer_id) do
    handshake = Handshake.init(info_hash, peer_id) |> Handshake.serialize()
    socket |> Socket.Stream.send!(handshake)
    socket
  end

  def receive_handshake(socket) do
    IO.puts("In receive_handshake")
    socket |> Socket.packet!(:raw)

    message = socket |> recv_byte!(1)
    IO.puts("Message: #{message}")

    request_length = message |> :binary.bin_to_list() |> Enum.at(0)

    %{
      pstrlen: request_length,
      pstr: recv_byte!(socket, request_length),
      placeholder: recv_byte!(socket, 8),
      info_hash: recv_byte!(socket, 20),
      peer_id: recv_byte!(socket, 20)
    }
  end

  @doc """
  Instruct the server to report the current GenServer state
  """
  def report(server) do
    GenServer.call(server, :report)
  end

  @doc """
  Instruct the server to complete a handshake with the remaining peers
  Only retains peers with whom we're able to complete a handshake
  """
  def complete_handshake(server, peer) do
    # TODO: Start here
  end

  def recv_byte!(socket, count) do
    case socket |> Socket.Stream.recv(count) do
      {:error, _} ->
        IO.puts("Received Error. Exiting...")
        exit(:normal)

      {:ok, nil} ->
        IO.puts("Received nil. Exiting...")
        exit(:normal)

      {:ok, message} ->
        message
    end
  end
end
