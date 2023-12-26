defmodule Handshake do
  @protocol "BitTorrent Protocol"
  @capabilities <<0, 0, 0, 0, 0, 0, 0, 0>>

  @protocol_length byte_size(@protocol)

  @enforce_keys [:info_hash, :peer_id]
  defstruct [:info_hash, :peer_id]

  def init(info_hash, peer_id) do
    %Handshake{info_hash: info_hash, peer_id: peer_id}
  end

  @doc """
  Generate a handshake message to send to peers
  """
  def serialize(handshake) do
    info_hash = handshake.info_hash
    peer_id = handshake.peer_id

    <<@protocol_length>> <> @protocol <> @capabilities <> info_hash <> peer_id
  end

  @doc """
  Parses a handshake from a stream
  """
  def deserialize(stream) when byte_size(stream) == 68 do
    <<protocol_length::integer, _protocol::binary-size(protocol_length),
      _capabilities::binary-size(8), info_hash::binary-size(20),
      peer_id::binary-size(20)>> = stream

    {:ok, %Handshake{info_hash: info_hash, peer_id: peer_id}}
  end

  def deserialize(_stream) do
    {:error, :invalid_byte_size}
  end
end
