defmodule Peer do
  @moduledoc """
  A struct representing a peer.
  """
  defstruct [:ip, :port, :ip_tuple, :pid]
  require Logger

  # Timeout in milliseconds for initiating a peer connection
  @timeout 3000

  @doc """
  Parses a peer's binary data into a Peer struct
  """
  def build_peer(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip = "#{ip0}.#{ip1}.#{ip2}.#{ip3}"

    Logger.info("Parsed peer IP: #{ip} Port: #{port}")

    %Peer{ip: ip, ip_tuple: {ip0, ip1, ip2, ip3}, port: port}
  end

  @doc """
  Create a connection to the specified peer
  """
  def connect(peer) do
    # Socket.TCP.connect(peer.ip, peer.port, timeout: @timeout)
    case :gen_tcp.connect(peer.ip_tuple, peer.port, [:binary, active: false], @timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :econnrefused} ->
        {:error, "Connection refused"}

      {:error, :etimedout} ->
        {:error, "Connection timed out"}

      {:error, _} ->
        {:error, "Failed to connect to peer"}
    end
  end
end
