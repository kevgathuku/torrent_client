defmodule TorrentClient.Requests.TeslaClient do
  @moduledoc """
  Real tracker HTTP implementation via Tesla.
  """

  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  def get(url) do
    Tesla.get(url)
  end
end
