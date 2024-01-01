defmodule Utils do
  @port_range 1..65535
  @ip_pool for n <- 1..254, do: <<192, 168, 1, n>>

  @doc """
  Generate a 20-character random string, to use as the peer id
  """
  def generate_peer_id() do
    :crypto.strong_rand_bytes(20) |> Base.encode64() |> binary_part(0, 20)
  end

  def single_file_torrent do
    "test/_data/debian-12.4.0-amd64-netinst.iso.torrent"
  end

  def multi_file_torrent do
    "test/_data/big-buck-bunny.torrent"
  end

  def get_port do
    # TODO: Improve to choose free port
    Enum.random(6881..6889)
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
