defmodule PeerTest do
  use ExUnit.Case, async: true

  describe "build_peer/1 (IPv4 compact peer)" do
    test "parses ip and port" do
      # 192.168.1.10:8080
      assert Peer.build_peer(<<192, 168, 1, 10, 0x1F, 0x90>>) == %Peer{
               ip_tuple: {192, 168, 1, 10},
               port: 8080
             }
    end
  end

  describe "parse_compact/2" do
    test "parses a list of IPv4 peers" do
      compact = <<192, 168, 1, 10, 0x1F, 0x90, 10, 0, 0, 1, 0x00, 0x50>>

      assert {:ok,
              [
                %Peer{ip_tuple: {192, 168, 1, 10}, port: 8080},
                %Peer{ip_tuple: {10, 0, 0, 1}, port: 80}
              ]} =
               Peer.parse_compact(compact, :ipv4)
    end

    test "parses an IPv6 peer" do
      # 2001:db8::1 port 8080
      compact = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x1F, 0x90>>

      assert {:ok, [%Peer{ip_tuple: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, port: 8080}]} =
               Peer.parse_compact(compact, :ipv6)
    end

    test "empty binary parses to no peers" do
      assert {:ok, []} = Peer.parse_compact(<<>>, :ipv4)
      assert {:ok, []} = Peer.parse_compact(<<>>, :ipv6)
    end

    test "misaligned binary is an error, not a crash" do
      assert {:error, _} = Peer.parse_compact(<<1, 2, 3, 4, 5>>, :ipv4)
      assert {:error, _} = Peer.parse_compact(<<1, 2, 3>>, :ipv6)
    end
  end

  describe "parse_address/1 (tracker text, literal only)" do
    test "parses dotted quads" do
      assert {:ok, {1, 2, 3, 4}} = Peer.parse_address("1.2.3.4")
    end

    test "parses full IPv6" do
      assert {:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}} =
               Peer.parse_address("2001:0db8:0000:0000:0000:0000:0000:0001")
    end

    test "parses compressed IPv6" do
      assert {:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}} = Peer.parse_address("2001:db8::1")
    end

    test "parses mapped IPv6" do
      assert {:ok, {0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304}} =
               Peer.parse_address("::ffff:1.2.3.4")
    end

    test "rejects hostnames without resolving them" do
      assert {:error, :unparseable_peer_address} = Peer.parse_address("tracker.example.com")
      assert {:error, :unparseable_peer_address} = Peer.parse_address("not-an-ip")
    end

    test "rejects blank and non-string input" do
      assert {:error, :unparseable_peer_address} = Peer.parse_address("")
      assert {:error, :unparseable_peer_address} = Peer.parse_address(nil)
    end
  end

  describe "usable?/1 (dial filter)" do
    test "keeps public and private unicast" do
      assert Peer.usable?(%Peer{ip_tuple: {1, 2, 3, 4}, port: 6881})
      assert Peer.usable?(%Peer{ip_tuple: {10, 0, 0, 1}, port: 6881})
      assert Peer.usable?(%Peer{ip_tuple: {192, 168, 1, 1}, port: 6881})

      assert Peer.usable?(%Peer{ip_tuple: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, port: 6881})
    end

    test "drops IPv4 loopback, unspecified, link-local, multicast" do
      for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0}, {169, 254, 1, 1}, {224, 0, 0, 1}, {239, 1, 2, 3}] do
        refute Peer.usable?(%Peer{ip_tuple: ip, port: 6881}), "#{inspect(ip)} must not dial"
      end
    end

    test "drops IPv6 loopback, unspecified, link-local, multicast" do
      for ip <- [
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1}
          ] do
        refute Peer.usable?(%Peer{ip_tuple: ip, port: 6881}), "#{inspect(ip)} must not dial"
      end
    end

    test "mapped addresses follow the embedded IPv4" do
      # ::ffff:127.0.0.1 is still loopback; ::ffff:1.2.3.4 is usable.
      refute Peer.usable?(%Peer{ip_tuple: {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}, port: 6881})
      assert Peer.usable?(%Peer{ip_tuple: {0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304}, port: 6881})
    end

    test "fails closed on malformed tuples" do
      refute Peer.usable?(%Peer{ip_tuple: {1, 2, 3}, port: 6881})
      refute Peer.usable?(%Peer{ip_tuple: {}, port: 6881})
    end

    test "filter_usable/1 keeps only dialable peers" do
      peers = [
        %Peer{ip_tuple: {1, 2, 3, 4}, port: 6881},
        %Peer{ip_tuple: {1, 2, 3, 4}, port: 0},
        %Peer{ip_tuple: {127, 0, 0, 1}, port: 6881},
        %Peer{ip_tuple: {0, 0, 0, 0, 0, 0, 0, 1}, port: 6881}
      ]

      assert [%Peer{ip_tuple: {1, 2, 3, 4}}] = Peer.filter_usable(peers)
    end
  end
end
