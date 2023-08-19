defmodule Client do
  @moduledoc """
  Entry point for the Client.
  Connects to a peer
  """

  require Logger
  use GenServer

  # Timeout in milliseconds for connecting to a peer
  @timeout 3000

  def start_link(torrent, peer, peer_id) do
    state = %{
      peer: peer,
      info_hash: torrent.info_hash,
      peer_id: peer_id
    }

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init_connection(server) do
    # TODO: Start from here. Debug this connection and ensure we can connect to the peer
    GenServer.cast(server, :init_connection)
  end

  @doc """
  Complete a handshake with a peer
  """
  def complete_handshake(server) do
    GenServer.cast(server, :complete_handshake)
  end

  @doc """
  Instruct the server to report the current GenServer state
  """
  def report(server) do
    GenServer.call(server, :report)
  end

  # Server callbacks
  @impl true
  def init(init_state) do
    GenServer.cast(self(), :init_connection)
    {:ok, init_state}
  end

  @impl true
  def handle_cast(
        :init_connection,
        %{peer: peer} = state
      ) do
    case connect(peer) do
      {:ok, socket} ->
        IO.puts("Peer: " <> peer.ip <> " is connected")

        {:noreply, %{state | socket: socket}}

      {:error, _} ->
        {:stop, "ERROR: Unable to connect to Peer: #{peer.ip}", state}
    end
  end

  @impl true
  def handle_cast(:complete_handshake, state) do
    %{socket: socket, info_hash: info_hash, peer_id: peer_id, peer: peer} = state

    response =
      socket
      |> send_handshake(info_hash, peer_id)
      |> receive_handshake

    IO.puts("Response from handshake with: #{peer.ip}")
    IO.inspect(response)

    verify_checksum(response.info_hash, info_hash)

    {:noreply, state}
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
    # Socket.TCP.connect(peer.ip, peer.port, timeout: @timeout)
    case :gen_tcp.connect(peer.ip_tuple, peer.port, [:binary, active: false], @timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :econnrefused} ->
        {:error, "Connection refused"}

      {:error, :etimedout} ->
        {:error, "Connection timed out"}

      {:error, _} ->
        {:error, "Failed to connect to peer"}
    end
  end

  def send_handshake(socket, info_hash, peer_id) do
    handshake = Handshake.init(info_hash, peer_id) |> Handshake.serialize()

    try do
      socket |> Socket.Stream.send!(handshake)
    rescue
      _e ->
        exit(:normal)
    end

    socket
  end

  def receive_handshake(socket) do
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

  def verify_checksum(received_hash, info_hash) do
    if received_hash != info_hash do
      IO.puts("Wrong checksum")
      exit(:wrong_checksum)
    end
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
