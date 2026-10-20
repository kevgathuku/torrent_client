defmodule PeerCompactPropertyTest do
  @moduledoc """
  Round-trip properties for compact peer parsing. The encoding side is built
  with plain bitstring syntax in the test, independently of `Peer`, so the
  property can genuinely disagree with the implementation.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  defp ipv4_gen do
    gen all a <- integer(0..255),
            b <- integer(0..255),
            c <- integer(0..255),
            d <- integer(0..255),
            port <- integer(1..65_535) do
      {{a, b, c, d}, port}
    end
  end

  defp ipv6_gen do
    gen all segments <- list_of(integer(0..65_535), length: 8),
            port <- integer(1..65_535) do
      {List.to_tuple(segments), port}
    end
  end

  defp encode_ipv4({a, b, c, d}, port), do: <<a, b, c, d, port::16-big>>

  defp encode_ipv6({s1, s2, s3, s4, s5, s6, s7, s8}, port) do
    <<s1::16-big, s2::16-big, s3::16-big, s4::16-big, s5::16-big, s6::16-big, s7::16-big,
      s8::16-big, port::16-big>>
  end

  property "IPv4 compact lists round-trip" do
    check all peers <- list_of(ipv4_gen()) do
      compact = Enum.map_join(peers, &encode_ipv4(elem(&1, 0), elem(&1, 1)))

      expected =
        Enum.map(peers, fn {ip, port} -> %Peer{ip_tuple: ip, port: port} end)

      assert {:ok, expected} == Peer.parse_compact(compact, :ipv4)
    end
  end

  property "IPv6 compact lists round-trip" do
    check all peers <- list_of(ipv6_gen()) do
      compact = Enum.map_join(peers, &encode_ipv6(elem(&1, 0), elem(&1, 1)))

      expected =
        Enum.map(peers, fn {ip, port} -> %Peer{ip_tuple: ip, port: port} end)

      assert {:ok, expected} == Peer.parse_compact(compact, :ipv6)
    end
  end

  property "misaligned binaries are errors" do
    check all len <- member_of(Enum.reject(0..40, &(rem(&1, 6) == 0))),
              bytes <- list_of(byte(), length: len) do
      assert {:error, _} = Peer.parse_compact(:erlang.list_to_binary(bytes), :ipv4)
    end
  end
end
