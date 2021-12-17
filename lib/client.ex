defmodule Client do
  @moduledoc """
  Entry point for the Client.
  Connects to a peer
  """

  require Logger

  use GenServer

  @initial_state %{socket: nil, peer: nil, torrent: nil}

  def start_link(torrent) do
    state = @initial_state |> Map.put(:torrent, torrent)
    GenServer.start_link(__MODULE__, state, name: PeerClient)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:connect, peer}, _from, state) do
    opts = [:binary, active: false]
    {:ok, address} = :inet.parse_address(peer.ip)

    # timeout -> 3 seconds
    case :gen_tcp.connect(address, peer.port, opts, 3000) do
      {:ok, socket} ->
        Logger.info("Connected with #{peer.ip}")

        {:reply, :ok, %{state | socket: socket, peer: peer}}

      {:error, reason} ->
        Logger.error("Could not connect: #{reason}")
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_call(:handshake, _from, state) do
    %{socket: socket, torrent: %{info_hash: info_hash, peer_id: peer_id}} = state

    handshake = Handshake.init(info_hash, peer_id) |> Handshake.serialize()

    :ok = :gen_tcp.send(socket, handshake)

    # `0` means receive all available bytes on the socket.
    case :gen_tcp.recv(socket, 0) do
      {:ok, msg} ->
        IO.puts("Received msg" <> msg)
        {:ok, parsed_handshake} = Handshake.deserialize(msg)

        IO.puts("parsed_handshake")
        IO.inspect(parsed_handshake)

        {:reply, parsed_handshake, state}

      {:error, error} ->
        IO.puts("ERROR")
        IO.inspect(error)
        {:reply, error, state}
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
  def connect(server, peer) do
    GenServer.call(server, {:connect, peer})
  end

  @doc """
  Instruct the server to report the current GenServer state
  """
  def report(server) do
    GenServer.call(server, :report)
  end

  @doc """
  Instruct the server to complete a handshake with a peer
  Sends a handshake and ensures we get a valid response back
  """
  def complete_handshake(server) do
    response = GenServer.call(server, :handshake)

    IO.puts("RESPONSE")
    IO.inspect(response)
  end
end
