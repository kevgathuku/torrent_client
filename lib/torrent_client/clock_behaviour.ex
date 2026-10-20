defmodule TorrentClient.ClockBehaviour do
  @moduledoc """
  Time edge. The real implementation reads the system clock; tests substitute
  `TorrentClient.ClockMock`. Workers receive the impl via start opts.
  (First real caller lands in kog.9.)
  """

  @doc "Monotonic milliseconds, for timeouts and backoff."
  @callback monotonic_ms() :: integer()
end
