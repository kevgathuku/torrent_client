defmodule Utils do
  @doc """
  Generate a 20-character random string, to use as the peer id
  """
  def generate_peer_id() do
    :crypto.strong_rand_bytes(20) |> Base.encode64() |> binary_part(0, 20)
  end

  def single_file_torrent do
    "test/_data/debian-12.1.0-amd64-netinst.iso.torrent"
  end

  def multi_file_torrent do
    "test/_data/2718B3EC2A16AED3EF5A3DFD551EF7CCC5CC398B.torrent"
  end

  def sha_sum(binary) do
    :crypto.hash(:sha, binary)
  end
end
