defmodule Peer do
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

  def extract_peers(data) when is_binary(data) do
    peer_size = 6
    num_peers = (byte_size(data) / peer_size) |> floor

    # Extract peers from the binary data into a list of peers
    Enum.reduce(0..(num_peers - 1), [], fn index, acc ->
      List.insert_at(acc, index, binary_part(data, index * peer_size, peer_size))
    end)
    |> Enum.map(&parse_peer/1)
  end

  @doc """
  Parses binary data into a Peer struct
  """
  def parse_peer(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip = to_charlist("#{ip0}.#{ip1}.#{ip2}.#{ip3}")

    %Peer{ip: ip, port: port}
  end
end
