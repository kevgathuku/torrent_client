defmodule TorrentClient.Requests.RequestsTeslaImpl do
  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  @spec get(binary()) :: {:error, any()} | {:ok, Tesla.Env.t()}
  def get(args) do
    Tesla.get(args)
  end
end
