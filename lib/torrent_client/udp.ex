defmodule TorrentClient.Udp do
  @moduledoc """
  Real UDP transport. Effectful by design — everything in here stays out
  of the domain layer. Untestable without real sockets by design; behavior
  is covered through `TorrentClient.UdpMock`.
  """

  @behaviour TorrentClient.UdpBehaviour

  @impl true
  def send_recv(host, port, packet, timeout_ms) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]),
         :ok <- :gen_udp.send(socket, String.to_charlist(host), port, packet) do
      result =
        case :gen_udp.recv(socket, 0, timeout_ms) do
          {:ok, {address, _port, data}} -> {:ok, %{family: family(address), data: data}}
          {:error, _} = error -> error
        end

      :gen_udp.close(socket)
      result
    end
  end

  defp family(address) when tuple_size(address) == 4, do: :inet
  defp family(_address), do: :inet6
end
