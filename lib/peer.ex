defmodule Peer do
  @moduledoc """
  A peer address: IP tuple plus port.

  Pure parsing only — connecting lives in `TorrentClient.Network`.
  `ip_tuple` is a 4-tuple for IPv4 and an 8-tuple of 16-bit segments for IPv6.
  """
  defstruct [:port, :ip_tuple]
  require Logger

  @ipv4_peer_size 6
  @ipv6_peer_size 18

  @doc """
  Parses a compact peer list (concatenated fixed-size entries) into peers.
  IPv4 entries are 6 bytes (4 IP + 2 port); IPv6 entries are 18 bytes
  (16 IP + 2 port). A truncated trailing entry is an error, never a crash.
  """
  def parse_compact(binary, :ipv4), do: parse_list(binary, @ipv4_peer_size, &build_peer/1)
  def parse_compact(binary, :ipv6), do: parse_list(binary, @ipv6_peer_size, &build_peer6/1)

  @doc """
  Parses a single 18-byte IPv6 compact peer into a Peer struct.
  """
  def build_peer6(
        <<a::16-big, b::16-big, c::16-big, d::16-big, e::16-big, f::16-big, g::16-big, h::16-big,
          port::16-big>>
      ) do
    %Peer{ip_tuple: {a, b, c, d, e, f, g, h}, port: port}
  end

  defp parse_list(binary, size, fun), do: parse_list(binary, size, fun, [])

  defp parse_list(<<>>, _size, _fun, acc), do: {:ok, :lists.reverse(acc)}

  defp parse_list(binary, size, fun, acc) when byte_size(binary) >= size do
    {chunk, rest} = :erlang.split_binary(binary, size)
    parse_list(rest, size, fun, [fun.(chunk) | acc])
  end

  defp parse_list(_binary, _size, _fun, _acc) do
    {:error, "malformed compact peers: truncated entry"}
  end

  @doc """
  Parses a single 6-byte IPv4 compact peer into a Peer struct.
  """
  def build_peer(data) when is_binary(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip_tuple = {ip0, ip1, ip2, ip3}

    Logger.info("Parsed peer IP: #{inspect(ip_tuple)} Port: #{port}")

    %Peer{ip_tuple: ip_tuple, port: port}
  end
end
