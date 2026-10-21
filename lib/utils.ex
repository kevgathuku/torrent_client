defmodule Utils do
  @moduledoc """
  Small shared helpers: peer ids, free ports, hashing, and fake peer bytes
  for tests. No torrent logic lives here.
  """

  @port_range 1..65_535
  @ip_pool for n <- 1..254, do: <<192, 168, 1, n>>

  @doc """
  Generate a 20-character random string, to use as the peer id
  """
  def generate_peer_id do
    :crypto.strong_rand_bytes(20) |> Base.encode64() |> binary_part(0, 20)
  end

  @doc """
  Ask the OS for a free TCP port by binding port 0 and releasing it.
  Best-effort: another process may claim the port before we bind it.
  """
  def get_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  def sha_sum(binary) do
    :crypto.hash(:sha, binary)
  end

  def generate_n_peers(num) do
    valid_addresses =
      for ip <- Enum.take_random(@ip_pool, num),
          do: <<ip::binary, Enum.random(@port_range)::size(16)>>

    Enum.reduce(valid_addresses, fn address, acc -> <<acc::binary, address::binary>> end)
  end
end
