defmodule TorrentClient.SocketBehaviour do
  @moduledoc """
  Connected-socket edge: framed send/receive/close on a peer socket opened
  by `TorrentClient.Network`. The default implementation delegates to
  `:gen_tcp`; tests substitute a scripted double. Workers receive the impl
  via start opts.
  """

  @doc "Send bytes on the socket."
  @callback send(socket :: term(), bytes :: iodata()) :: :ok | {:error, term()}

  @doc "Receive exactly `count` bytes, up to `timeout` ms."
  @callback recv(socket :: term(), count :: non_neg_integer(), timeout :: timeout()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Close the socket."
  @callback close(socket :: term()) :: :ok | {:error, term()}
end
