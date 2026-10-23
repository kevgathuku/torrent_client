defmodule Handshake do
  @moduledoc """
  BEP-3 handshake codec: 68-byte greeting with the peer's info-hash.
  """

  # BEP-3's exact identifier: lowercase 'p'. Strict peers (Transmission)
  # drop the handshake otherwise; our own seeds accept anything, which
  # is why only a real client caught this.
  @protocol "BitTorrent protocol"
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
  def serialize(%__MODULE__{info_hash: info_hash, peer_id: peer_id})
      when byte_size(info_hash) == 20 and byte_size(peer_id) == 20 do
    <<@protocol_length>> <> @protocol <> @capabilities <> info_hash <> peer_id
  end

  @doc """
  Parses a handshake from a stream
  """
  def deserialize(<<plen::8, rest::binary>>) when byte_size(rest) == 67 do
    if plen == @protocol_length do
      <<_protocol::binary-size(^plen), _capabilities::binary-size(8), info_hash::binary-size(20),
        peer_id::binary-size(20)>> = rest

      {:ok, %Handshake{info_hash: info_hash, peer_id: peer_id}}
    else
      {:error, :bad_handshake}
    end
  end

  def deserialize(_stream) do
    {:error, :invalid_byte_size}
  end
end
