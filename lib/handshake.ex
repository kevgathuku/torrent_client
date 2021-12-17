defmodule Handshake do
  @protocol "BitTorrent Protocol"
  @capabilities <<0, 0, 0, 0, 0, 0, 0, 0>>

  @enforce_keys [:info_hash, :peer_id]
  defstruct [:info_hash, :peer_id]

  def init(info_hash, peer_id) do
    IO.puts("INIT HS:" <> "PEER ID:" <> peer_id)

    %Handshake{info_hash: info_hash, peer_id: peer_id}
  end

  @doc """
  Generate a handshake message to send to peers
  """
  def serialize(handshake) do
    info_hash = handshake.info_hash
    peer_id = handshake.peer_id
    protocol_length = byte_size(@protocol)

    <<protocol_length>> <> @protocol <> @capabilities <> info_hash <> peer_id
  end

  @doc """
  Parses a handshake from a stream
  """
  def deserialize(stream) do
    protocol_len_bits = byte_size(@protocol) * 8
    capabilities_len_bits = byte_size(@capabilities) * 8
    peer_len_bits = info_hash_len_bits = 20 * 8

    <<protocol_length::8>> <>
      <<protocol::binary-size(protocol_len_bits)>> <>
      <<_capabilities::binary-size(capabilities_len_bits)>> <>
      <<info_hash::binary-size(info_hash_len_bits)>> <> <<peer_id::binary-size(peer_len_bits)>> =
      stream

    IO.puts("DES: protocol_length:", protocol_length)
    IO.puts("DES: protocol:" <> protocol)
    IO.puts("DES: Info hash:" <> info_hash)
    IO.puts("DES: peer_id:" <> peer_id)

    {:ok, %Handshake{info_hash: info_hash, peer_id: peer_id}}
  end
end
