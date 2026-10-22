defmodule TorrentClient.Requests.TeslaClient do
  @moduledoc """
  Real tracker HTTP implementation via Tesla.

  Every query carries its own inner timeout so one blackholed tracker
  fails fast instead of eating the whole announce fan-out window (the
  fan-out timeout stays the outer bound; this only frees its task
  slot early).
  """

  @behaviour TorrentClient.Requests.RequestsBehaviour

  # Well under the 10s session announce window: a dead tracker is
  # reported quickly while slow-but-live ones still answer.
  @default_timeout 5_000

  @impl true
  def get(url) do
    Tesla.client([{Tesla.Middleware.Timeout, timeout: timeout()}])
    |> Tesla.get(url)
  end

  # Overridable for tests (a 5s hang per case would stall the suite).
  defp timeout do
    Application.get_env(:torrent_client, :requests_timeout, @default_timeout)
  end
end
