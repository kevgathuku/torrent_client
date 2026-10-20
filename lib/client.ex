defmodule Client do
  @moduledoc """
  Entry point for the Client.
  Connects to a peer
  """

  require Logger
  use GenServer

  def start_link(torrent, peer, peer_id, opts \\ []) do
    state = %{
      peer: peer,
      info_hash: torrent.info_hash,
      peer_id: peer_id,
      network: Keyword.get(opts, :network, TorrentClient.Network)
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

  # Server callbacks
  @impl true
  def init(state) do
    # TODO: Check if this should be done in a continue block
    GenServer.cast(self(), :init_connection)
    {:ok, state}
  end

  @impl true
  def handle_cast(
        :init_connection,
        %{peer: peer, network: network} = state
      ) do
    case network.connect(peer) do
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
    Logger.debug("Handshake response: #{inspect(response)}")

    verify_checksum(response.info_hash, info_hash)

    {:noreply, state}
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
