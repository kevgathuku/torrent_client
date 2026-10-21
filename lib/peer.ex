defmodule Peer do
  @moduledoc """
  A peer address: IP tuple plus port.

  Pure parsing only — connecting lives in `TorrentClient.Network`.
  `ip_tuple` is a 4-tuple for IPv4 and an 8-tuple of 16-bit segments for IPv6.
  """
  defstruct [:port, :ip_tuple]
  require Logger

  @type t :: %__MODULE__{ip_tuple: tuple(), port: non_neg_integer()}

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

  @doc """
  Parses tracker-supplied address text into an IP tuple.

  Literal only: dotted quads plus full, compressed, and IPv4-mapped IPv6
  forms. Hostnames are an error — this path never touches DNS, so a
  tracker can neither stall nor redirect us through resolution.
  """
  @spec parse_address(term()) :: {:ok, :inet.ip_address()} | {:error, :unparseable_peer_address}
  def parse_address(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> {:error, :unparseable_peer_address}
    end
  end

  def parse_address(_), do: {:error, :unparseable_peer_address}

  @doc """
  Whether the peer is worth dialing.

  Drops loopback, unspecified, link-local, and multicast ranges for both
  families, plus peers with no dialable port (0 or out of range — compact
  ports arrive as a 16-bit field, so only 0 is possible there).
  IPv4-mapped IPv6 addresses are judged by their embedded IPv4 address,
  so `::ffff:127.0.0.1` is still loopback. Private unicast (10/8,
  192.168/16, fc00::/7) stays dialable — LAN swarms are real.
  """
  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{ip_tuple: tuple, port: port}) when port in 1..65_535 do
    usable_tuple?(tuple)
  end

  def usable?(%__MODULE__{}), do: false

  @doc "Keeps only the dialable peers of the list."
  @spec filter_usable([t()]) :: [t()]
  def filter_usable(peers), do: Enum.filter(peers, &usable?/1)

  # IPv4: loopback 127/8, unspecified, link-local 169.254/16, multicast 224/4.
  defp usable_tuple?({127, _, _, _}), do: false
  defp usable_tuple?({0, 0, 0, 0}), do: false
  defp usable_tuple?({169, 254, _, _}), do: false
  defp usable_tuple?({a, _, _, _}) when a in 224..239, do: false
  defp usable_tuple?({_, _, _, _}), do: true

  # Mapped addresses inherit the verdict of their embedded IPv4 address.
  defp usable_tuple?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    usable_tuple?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  end

  # IPv6: loopback ::1, unspecified ::, link-local fe80::/10, multicast ff00::/8.
  defp usable_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp usable_tuple?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp usable_tuple?({hi, _, _, _, _, _, _, _}) when hi in 0xFE80..0xFEBF, do: false
  defp usable_tuple?({hi, _, _, _, _, _, _, _}) when hi in 0xFF00..0xFFFF, do: false
  defp usable_tuple?({_, _, _, _, _, _, _, _}), do: true

  # Anything else is not an address we know how to dial.
  defp usable_tuple?(_), do: false

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
