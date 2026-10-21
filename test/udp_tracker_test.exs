defmodule UdpTrackerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias TorrentClient.UdpTracker

  describe "connect" do
    test "encodes the BEP-15 magic handshake" do
      assert UdpTracker.encode_connect(0xAABBCCDD) ==
               {:ok, <<0x41727101980::64-big, 0::32-big, 0xAABBCCDD::32-big>>}
    end

    test "decodes a connect response, checking the transaction id" do
      assert UdpTracker.decode_connect(
               <<0::32-big, 0xAABBCCDD::32-big, 0x1234::64-big>>,
               0xAABBCCDD
             ) ==
               {:ok, %{connection_id: 0x1234}}
    end

    test "rejects a mismatched transaction id" do
      assert {:error, _} =
               UdpTracker.decode_connect(
                 <<0::32-big, 0x11111111::32-big, 0x1234::64-big>>,
                 0xAABBCCDD
               )
    end

    test "rejects a truncated response" do
      assert {:error, _} = UdpTracker.decode_connect(<<0::32-big, 1, 2, 3>>, 0xAABBCCDD)
    end
  end

  describe "announce" do
    test "encodes an IPv4 announce request per BEP-15 offsets" do
      params = %{
        connection_id: 0x1234,
        transaction_id: 0xAABBCCDD,
        info_hash: :binary.copy(<<1>>, 20),
        peer_id: :binary.copy(<<2>>, 20),
        downloaded: 0,
        left: 100,
        uploaded: 0,
        event: 0,
        ip: 0,
        key: 0x42,
        num_want: -1,
        port: 6881
      }

      assert {:ok, bin} = UdpTracker.encode_announce(params)
      assert byte_size(bin) == 98

      assert <<0x1234::64-big, 1::32-big, 0xAABBCCDD::32-big, rest::binary>> = bin
      assert binary_part(rest, 0, 20) == :binary.copy(<<1>>, 20)
    end

    test "decodes an IPv4 announce response" do
      peers = <<192, 168, 1, 1, 0x1F, 0x90>>
      bin = <<1::32-big, 0xAABBCCDD::32-big, 60::32-big, 0::32-big, 1::32-big, peers::binary>>

      assert UdpTracker.decode_announce(bin, 0xAABBCCDD) ==
               {:ok, %{interval: 60, leechers: 0, seeders: 1, peers: peers}}
    end

    test "decodes an IPv6 announce response with 18-byte stride" do
      peers = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x1F, 0x90>>
      assert byte_size(peers) == 18

      bin =
        <<1::32-big, 0xAABBCCDD::32-big, 60::32-big, 0::32-big, 1::32-big, peers::binary>>

      assert {:ok, %{peers: ^peers}} = UdpTracker.decode_announce(bin, 0xAABBCCDD, :ipv6)
    end

    test "decodes an error packet" do
      bin = <<3::32-big, 0xAABBCCDD::32-big, "unregistered torrent">>
      assert {:error, "unregistered torrent"} = UdpTracker.decode_announce(bin, 0xAABBCCDD)
    end

    test "truncated announce response is an error" do
      assert {:error, _} = UdpTracker.decode_announce(<<1::32-big, 1, 2, 3>>, 0xAABBCCDD)
    end
  end

  property "connect round-trips" do
    check all(xid <- integer(0..0xFFFFFFFF), conn <- integer(0..0xFFFFFFFFFFFFFFFF)) do
      assert {:ok, req} = UdpTracker.encode_connect(xid)
      assert {:ok, resp} = UdpTracker.encode_connect_response(xid, conn)
      assert UdpTracker.decode_connect(resp, xid) == {:ok, %{connection_id: conn}}
      assert byte_size(req) == 16
    end
  end

  property "announce responses round-trip" do
    check all(
            xid <- integer(0..0xFFFFFFFF),
            interval <- integer(1..3600),
            seeders <- integer(0..1000),
            leechers <- integer(0..1000),
            peers <- binary(min_length: 0, max_length: 60)
          ) do
      # v4 stride: whole 6-byte entries only
      peers = binary_part(peers, 0, div(byte_size(peers), 6) * 6)

      assert {:ok, bin} =
               UdpTracker.encode_announce_response(xid, interval, leechers, seeders, peers)

      assert UdpTracker.decode_announce(bin, xid) ==
               {:ok, %{interval: interval, leechers: leechers, seeders: seeders, peers: peers}}
    end
  end

  property "single-field mutations are rejected" do
    # Only the action and transaction-id bytes: mutating counts or peer
    # bytes yields a different valid response, not a rejection.
    check all({bin, pos} <- header_mutation_case()) do
      assert {:error, _} = UdpTracker.decode_announce(corrupt_byte(bin, pos), 0xAABBCCDD)
    end
  end

  defp header_mutation_case do
    gen all(
          peer_list <- list_of(binary(min_length: 6, max_length: 6), max_length: 5),
          pos <- integer(0..7)
        ) do
      bin =
        <<1::32-big, 0xAABBCCDD::32-big, 60::32-big, 0::32-big, 1::32-big,
          :erlang.iolist_to_binary(peer_list)::binary>>

      {bin, pos}
    end
  end

  defp corrupt_byte(bin, pos) do
    {head, <<byte, rest::binary>>} = :erlang.split_binary(bin, pos)
    <<head::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>
  end
end
