defmodule Peer do
  defstruct [:ip, :port]

  require Logger

  @doc """
  Send a handshake to the specified peer
  """
  def handshake(peer) do
    # # Get handshake from Torrent.handshake_message
    # handshake = Torrent.handshake_message()
    #
    # # Send handshake message to peer
    # :gen_tcp.send(socket, handshake)

    # Send handshake to client and ensure we receive response back
  end

  @doc """
  Establish a connection to the specified peer
  """
  def connect(torrent, peer) do
    {:ok, address} = :inet.parse_address(peer.ip)

    # timeout -> 3 seconds
    case :gen_tcp.connect(address, peer.port, [active: false], 3000) do
      {:ok, socket} ->
        Logger.info("Connected with #{peer.ip}")

        # Get handshake from Torrent.handshake_message
        handshake = Torrent.handshake_message(torrent)

        # Send handshake message to peer
        :gen_tcp.send(socket, handshake)

        socket

      {:error, reason} ->
        Logger.error("Could not connect: #{reason}")
    end
  end

  @doc """
  Parses a peer's binary data into a Peer struct
  """
  def parse_peer(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip = to_charlist("#{ip0}.#{ip1}.#{ip2}.#{ip3}")

    %Peer{ip: ip, port: port}
  end
end
