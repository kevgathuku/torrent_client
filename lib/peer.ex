defmodule Peer do
  defstruct [:ip, :port]

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
  Extract peers from the tracker response's peers binary data
  """
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
  Parses a peer's binary data into a Peer struct
  """
  def parse_peer(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip = to_charlist("#{ip0}.#{ip1}.#{ip2}.#{ip3}")

    %Peer{ip: ip, port: port}
  end
end
