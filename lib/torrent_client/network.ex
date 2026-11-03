defmodule TorrentClient.Network do
  @moduledoc """
  Raw TCP edge: dials peers over `:gen_tcp`. Effectful by design — everything
  in here stays out of the domain layer. (Behaviour + doubles land in kog.3.)
  """

  @behaviour TorrentClient.NetworkBehaviour

  # Timeout in milliseconds for initiating a peer connection
  @timeout 3000

  @doc """
  Open a TCP connection to the peer. Returns the connected socket.
  `:gen_tcp` reasons pass through untouched so callers can match them.
  """
  @impl true
  def connect(peer) do
    :gen_tcp.connect(peer.ip_tuple, peer.port, [:binary, active: false], @timeout)
  end
end
