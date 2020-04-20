defmodule TorrentClient.Peer do
  defstruct [:ip, :port]

  require Logger

  @doc """
  Establish a connection to the specified peers
  """
  def connect(peer) do
    {:ok, address} = :inet.parse_address(peer.ip)

    # timeout -> 3 seconds
    case :gen_tcp.connect(address, peer.port, [active: false], 3000) do
      {:ok, socket} ->
        Logger.info("Completed handshake with #{peer.ip}")
        socket

      {:error, reason} ->
        Logger.error("Could not connect: #{reason}")
    end
  end
end
