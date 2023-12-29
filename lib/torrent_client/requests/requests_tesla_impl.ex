defmodule TorrentClient.Requests.RequestsTeslaImpl do
  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  def get(args) do
    Tesla.get(args)
  end
end
