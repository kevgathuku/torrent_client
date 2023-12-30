defmodule TorrentClient.Requests.TeslaClient do
  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  def get(url) do
    Tesla.get(url)
  end
end
