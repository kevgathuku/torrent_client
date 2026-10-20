defmodule TorrentClient.NetworkBehaviour do
  @moduledoc """
  Peer TCP edge. The real implementation dials `:gen_tcp`; tests substitute
  `TorrentClient.NetworkMock`. Workers receive the impl via start opts.
  """

  @doc "Open a TCP connection to the peer."
  @callback connect(peer :: term()) :: {:ok, term()} | {:error, term()}
end
