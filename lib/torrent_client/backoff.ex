defmodule TorrentClient.Backoff do
  @moduledoc """
  Shared pure exponential backoff: `base * 2^attempt` capped at `cap`.
  Randomness (jitter) and sleeping stay at the caller.
  """

  @doc "Delay in the same units as base/cap; never exceeds cap."
  def delay(attempt, base, cap) when is_integer(attempt) and attempt >= 0 do
    min(cap, base * Integer.pow(2, min(attempt, 62)))
  end
end
