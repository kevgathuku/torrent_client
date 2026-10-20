defmodule TorrentClient.Network do
  @moduledoc """
  Raw TCP edge: dials peers over `:gen_tcp`. Effectful by design — everything
  in here stays out of the domain layer. (Behaviour + doubles land in kog.3.)
  """

  # Timeout in milliseconds for initiating a peer connection
  @timeout 3000

  @doc """
  Open a TCP connection to the peer. Returns the connected socket.
  """
  def connect(peer) do
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
