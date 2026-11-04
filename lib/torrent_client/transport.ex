defmodule TorrentClient.Transport do
  @moduledoc """
  Named transports to their network/socket seam pair.

  `:tcp` is the default BitTorrent wire; `:utp` pairs `UtpNetwork` with
  `UtpSocket` (BEP-29). The coordinator and the peer workers resolve
  through here, so a new transport lands in one table instead of one
  clause per module. Explicit `:network`/`:sock` opts still win at each
  call site, and each caller validates the name itself.
  """

  @doc """
  The `{network, sock}` seam pair for a transport name. The pair is
  resolved together so the two halves can never disagree.
  """
  @spec pair(:tcp | :utp) :: {module(), module()}
  def pair(:tcp), do: {TorrentClient.Network, TorrentClient.GenTcpSocket}
  def pair(:utp), do: {TorrentClient.UtpNetwork, TorrentClient.UtpSocket}
end
