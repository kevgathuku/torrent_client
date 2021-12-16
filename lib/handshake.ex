defmodule Handshake do
  defstruct [:info_hash, :peer_id, protocol: "BitTorrent Protocol"]

  def init(torrent, peer_id) do
    %Handshake{info_hash: torrent.info_hash, peer_id: peer_id}
  end

  @doc """
  Generate a handshake message to send to peers
  """
  def serialize(handshake) do
    capabilities = <<0, 0, 0, 0, 0, 0, 0, 0>>
    info_hash = handshake.info_hash
    protocol = handshake.protocol
    peer_id = handshake.peer_id
    protocol_length = byte_size(protocol)

    <<protocol_length>> <> protocol <> capabilities <> info_hash <> peer_id
  end

  @doc """
  Parses a handshake from a stream
  """
  def deserialize(stream) do

  end
end
