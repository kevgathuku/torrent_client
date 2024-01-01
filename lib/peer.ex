defmodule Peer do
  @moduledoc """
  A struct representing a peer.
  """
  @enforce_keys [:ip_tuple, :port]
  defstruct [:port, :ip_tuple]

  require Logger
  use GenServer

  # Timeout in milliseconds for initiating a peer connection
  @timeout 3000

  @type t :: %__MODULE__{
          port: integer(),
          ip_tuple: tuple()
        }

  @doc """
  Build Peer struct from binary
  """
  def build_peer(data) when is_binary(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip_tuple = {ip0, ip1, ip2, ip3}

    Logger.info("Parsed peer IP: #{inspect(ip_tuple)} Port: #{port}")

    %Peer{ip_tuple: ip_tuple, port: port}
  end

  def init(peer) do
    GenServer.start_link(__MODULE__, peer)
  end

  @doc """
  Create a connection to the provided peer
  """
  def connect(%{ip_tuple: ip_tuple, port: port}, count \\ 0) do
    # Socket.TCP.connect(peer.ip, peer.port, timeout: @timeout)
    case :gen_tcp.connect(ip_tuple, port, [:binary, active: false], @timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :econnrefused} ->
        {:error, "Connection refused"}

      {:error, :etimedout} ->
        if count == 5 do
          Logger.info(
            "Unable to connect to " <> inspect(ip_tuple) <> " after 5 tries. Stopping now!"
          )

          {:error, "Connection timed out"}
        else
          connect(%Peer{ip_tuple: ip_tuple, port: port}, count + 1)
        end

      {:error, _} ->
        {:error, "Failed to connect to peer"}
    end
  end
end
