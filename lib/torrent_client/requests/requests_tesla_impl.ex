defmodule TorrentClient.Requests.RequestsTeslaImpl do
  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  def get(url) do
    Tesla.get(url)
  end
end
