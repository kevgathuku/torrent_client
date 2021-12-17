defmodule Client do
  @moduledoc """
  Entry point for the Client.
  Connects to a peer
  """

  require Logger

  use GenServer

  @initial_state %{socket: nil, peer: nil}

  def start_link do
    GenServer.start_link(__MODULE__, @initial_state, name: PeerClient)
  end

  @impl true
  def init(_state) do
    {:ok, @initial_state}
  end

  @impl true
  def handle_cast({:connect, peer}, state) do
    opts = [:binary, active: false]
    {:ok, address} = :inet.parse_address(peer.ip)

    # timeout -> 3 seconds
    case :gen_tcp.connect(address, peer.port, opts, 3000) do
      {:ok, socket} ->
        Logger.info("Connected with #{peer.ip}")

        {:noreply, %{state | socket: socket, peer: peer}}

      {:error, reason} ->
        Logger.error("Could not connect: #{reason}")
        {:noreply, %{state | peer: peer}}
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
    GenServer.cast(server, {:connect, peer})
  end

  @doc """
  Instruct the server to report the current GenServer state
  """
  def report(server) do
    GenServer.call(server, :report)
  end

  @doc """
  Send a handshake to the specified peer
  """
  def complete_handshake(server, info_hash, peer_id) do
    handshake = Handshake.init(info_hash, peer_id) |> Handshake.serialize()

    # Send handshake message to peer
    # TODO: Send this to the GenServer
    :gen_tcp.send(socket, handshake)

    # TODO: Receive response back
  end
end
