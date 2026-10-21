defmodule TorrentClient.GenTcpSocket do
  @moduledoc """
  Real socket implementation: thin delegation to `:gen_tcp`. Effectful by
  design — everything in here stays out of the domain layer.
  """

  @behaviour TorrentClient.SocketBehaviour

  @impl true
  def send(socket, bytes), do: :gen_tcp.send(socket, bytes)

  @impl true
  def recv(socket, count, timeout), do: :gen_tcp.recv(socket, count, timeout)

  @impl true
  def close(socket), do: :gen_tcp.close(socket)
end
