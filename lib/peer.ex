defmodule Peer do
  defstruct [:ip, :port]

  @doc """
  Parses a peer's binary data into a Peer struct
  """
  def parse_peer(data) do
    <<ip0::8-unsigned-big-integer, ip1::8-unsigned-big-integer, ip2::8-unsigned-big-integer,
      ip3::8-unsigned-big-integer, port::16-integer-big-unsigned>> = data

    ip = to_charlist("#{ip0}.#{ip1}.#{ip2}.#{ip3}")

    %Peer{ip: ip, port: port}
  end
end
