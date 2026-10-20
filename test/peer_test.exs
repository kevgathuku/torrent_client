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

      assert {:ok, [%Peer{ip_tuple: {192, 168, 1, 10}, port: 8080}, %Peer{ip_tuple: {10, 0, 0, 1}, port: 80}]} =
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
end
