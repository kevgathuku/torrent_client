defmodule TorrentClient.UdpBehaviour do
  @moduledoc """
  UDP datagram round-trip edge. One call owns the whole exchange (open,
  send, recv, close) so sockets never leak to callers. Tests substitute
  `TorrentClient.UdpMock`.
  """

  @doc "Send a datagram and wait for the reply, up to timeout_ms."
  @callback send_recv(
              host :: String.t(),
              port :: pos_integer(),
              packet :: binary(),
              timeout_ms :: pos_integer()
            ) ::
              {:ok, %{family: :inet | :inet6, data: binary()}} | {:error, term()}
end
