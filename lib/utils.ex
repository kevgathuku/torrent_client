defmodule Utils do
  @doc """
  Generate a 20-character random string, to use as the peer id
  """
  def generate_peer_id() do
    :crypto.strong_rand_bytes(20) |> Base.encode64() |> binary_part(0, 20)
  end

  def arch_torrent_file do
    "test/_data/archlinux-2019.12.01-x86_64.iso.torrent"
  end
end
