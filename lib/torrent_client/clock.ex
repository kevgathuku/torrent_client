defmodule TorrentClient.Clock do
  @moduledoc """
  Real clock implementation. Effectful by design — everything in here stays
  out of the domain layer.
  """

  @behaviour TorrentClient.ClockBehaviour

  @impl true
  def monotonic_ms, do: System.monotonic_time(:millisecond)
end
