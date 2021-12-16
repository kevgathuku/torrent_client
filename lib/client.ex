defmodule Client do
  @moduledoc """
  Entry point for the Client.
  """
  require Logger

  # use GenServer

  # @initial_state %{socket: nil}

  # def start_link do
  #   GenServer.start_link(__MODULE__, @initial_state)
  # end

  # def init(state) do
  #   opts = [:binary, active: false]
  #   {:ok, socket} = :gen_tcp.connect('localhost', 6379, opts)
  #   {:ok, %{state | socket: socket}}
  # end

  @doc """
  Connects with a peer, completes a handshake, and receives a handshake
  """
  def new(peer, peer_id, info_hash) do
    case connect(peer) do
      {:ok, socket} ->
        Logger.info("Connected with #{peer.ip}")

        # TODO: Send info_hash

        handshake = Handshake.init(info_hash, peer_id) |> Handshake.serialize()

        # Send handshake message to peer
        :gen_tcp.send(socket, handshake)

      # Send handshake to peer and ensure we receive response back

      {:error, reason} ->
        Logger.error("Could not connect: #{reason}")
    end
  end

  def parse_torrent_file(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def test_file do
    "test/_data/debian-10.2.0-amd64-netinst.iso.torrent"
  end

  def sample_bento_torrent() do
    test_file()
    |> parse_torrent_file()
  end

  @doc """
  Send a handshake to the specified peer
  """
  def complete_handshake(socket, peer) do
  end

  @doc """
  Establish a connection to the specified peer
  """
  def connect(peer) do
    {:ok, address} = :inet.parse_address(peer.ip)
    # timeout -> 3 seconds
    :gen_tcp.connect(address, peer.port, [active: false], 3000)
  end
end
