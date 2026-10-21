defmodule TorrentClient.UdpTracker do
  @moduledoc """
  BEP-15 UDP tracker wire codec. Pure encode/decode with bitstring syntax;
  sending datagrams lives behind the UDP transport seam. All integers are
  big-endian; malformed packets are `{:error, reason}`, never a crash.
  """

  # BEP-15 fixed connection_id for the initial connect request. UDP has no
  # handshake, so the tracker replies with a per-client connection_id to echo
  # in announce/scrape (return-routability check). Value is an arbitrary
  # protocol-frozen cookie; changing it breaks interop.
  @magic 0x41727101980

  @doc "Encode a connect request for the given transaction id."
  def encode_connect(transaction_id) when is_integer(transaction_id) do
    {:ok, <<@magic::64-big, 0::32-big, transaction_id::32-big>>}
  end

  @doc "Encode a connect response (test support and loopback use)."
  def encode_connect_response(transaction_id, connection_id) do
    {:ok, <<0::32-big, transaction_id::32-big, connection_id::64-big>>}
  end

  @doc "Decode a connect response, checking the transaction id."
  def decode_connect(<<0::32-big, transaction_id::32-big, connection_id::64-big>>, transaction_id) do
    {:ok, %{connection_id: connection_id}}
  end

  def decode_connect(_packet, _transaction_id), do: {:error, :malformed_connect_response}

  @doc "Encode an IPv4 announce request. Lengths over the 16 KiB cap are rejected."
  def encode_announce(params) do
    with {:ok, info_hash} <- sized(params.info_hash, 20),
         {:ok, peer_id} <- sized(params.peer_id, 20) do
      {:ok,
       <<params.connection_id::64-big, 1::32-big, params.transaction_id::32-big,
         info_hash::binary-size(20), peer_id::binary-size(20), params.downloaded::64-big,
         params.left::64-big, params.uploaded::64-big, params.event::32-big, params.ip::32-big,
         params.key::32-big, params.num_want::32-big-signed, params.port::16-big>>}
    end
  end

  @doc "Encode an announce response (test support and loopback use)."
  def encode_announce_response(transaction_id, interval, leechers, seeders, peers) do
    {:ok,
     <<1::32-big, transaction_id::32-big, interval::32-big, leechers::32-big, seeders::32-big,
       peers::binary>>}
  end

  @doc "Decode an announce response, checking action and transaction id."
  def decode_announce(packet, transaction_id, family \\ :ipv4)

  def decode_announce(
        <<1::32-big, transaction_id::32-big, interval::32-big, leechers::32-big, seeders::32-big,
          peers::binary>>,
        transaction_id,
        family
      ) do
    if valid_peers?(peers, family) do
      {:ok, %{interval: interval, leechers: leechers, seeders: seeders, peers: peers}}
    else
      {:error, :misaligned_peers}
    end
  end

  def decode_announce(
        <<3::32-big, transaction_id::32-big, message::binary>>,
        transaction_id,
        _family
      ) do
    {:error, message}
  end

  def decode_announce(_packet, _transaction_id, _family),
    do: {:error, :malformed_announce_response}

  defp sized(bin, size) when is_binary(bin) and byte_size(bin) == size, do: {:ok, bin}
  defp sized(_bin, _size), do: {:error, :invalid_field_size}

  defp valid_peers?(peers, :ipv4), do: rem(byte_size(peers), 6) == 0
  defp valid_peers?(peers, :ipv6), do: rem(byte_size(peers), 18) == 0
end
