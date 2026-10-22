defmodule ChaosSlowHttp do
  @moduledoc false
  # Slow-but-live webseed origin: answers 206 after a delay with
  # deterministic bytes, so tests can hash-match the piece up front.
  @behaviour TorrentClient.WebseedHttpBehaviour

  @delay 300
  @fill 0xAB

  @impl true
  def get(_url, headers) do
    Process.sleep(@delay)
    length = headers |> List.keyfind("range", 0) |> elem(1) |> range_length()
    {:ok, %Tesla.Env{status: 206, body: :binary.copy(<<@fill>>, length)}}
  end

  defp range_length("bytes=" <> rest) do
    [first, last] = String.split(rest, "-")
    String.to_integer(last) - String.to_integer(first) + 1
  end
end

defmodule ChaosHangHttp do
  @moduledoc false
  # Webseed origin that accepts the request and never answers: the
  # blackholed-server shape behind the webseed wedge.
  @behaviour TorrentClient.WebseedHttpBehaviour

  @impl true
  def get(_url, _headers) do
    Process.sleep(:infinity)
  end
end

defmodule ChaosErrorHttp do
  @moduledoc false
  # Webseed origin that fails every request immediately.
  @behaviour TorrentClient.WebseedHttpBehaviour

  @impl true
  def get(_url, _headers) do
    {:error, :chaos_down}
  end
end

defmodule ChaosRequestsHang do
  @moduledoc false
  # Tracker HTTP edge that never answers: proves the announce fan-out
  # timeout still bounds a hanging inner query.
  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  def get(_url) do
    Process.sleep(:infinity)
  end
end

defmodule ChaosSilentSocket do
  @moduledoc false
  # Connected socket that honors its timeout contract but never delivers
  # a byte: the silent-peer shape. A double that ignored `timeout`
  # would test nothing about our code, so recv sleeps out the clock.
  @behaviour TorrentClient.SocketBehaviour

  @impl true
  def send(_socket, _bytes), do: :ok

  @impl true
  def recv(_socket, _count, timeout) do
    Process.sleep(timeout)
    {:error, :timeout}
  end

  @impl true
  def close(_socket), do: :ok
end

defmodule ChaosHangNetwork do
  @moduledoc false
  # Peer TCP edge that never connects and never fails.
  @behaviour TorrentClient.NetworkBehaviour

  @impl true
  def connect(_peer) do
    Process.sleep(:infinity)
  end
end

defmodule ChaosErrorNetwork do
  @moduledoc false
  # Peer TCP edge that refuses every dial immediately.
  @behaviour TorrentClient.NetworkBehaviour

  @impl true
  def connect(_peer) do
    {:error, :chaos_refused}
  end
end
