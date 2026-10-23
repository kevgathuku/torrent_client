defmodule TorrentClient.UtpNetwork do
  @moduledoc """
  uTP dial edge: opens a `TorrentClient.UtpSocket` connection to the peer.
  Pairs with `UtpSocket` as the `:sock` impl — pass both via worker or
  coordinator opts, or pick `:transport: :utp` and let the coordinator
  pair them.
  """

  @behaviour TorrentClient.NetworkBehaviour

  alias TorrentClient.UtpSocket

  @impl true
  def connect(peer) do
    case UtpSocket.connect(peer.ip_tuple, peer.port, []) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
