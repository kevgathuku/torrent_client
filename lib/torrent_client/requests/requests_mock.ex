defmodule TorrentClient.Requests.RequestsMock do
  @moduledoc """
  In-memory tracker double: answers every announce with five fake peers.
  """

  @behaviour TorrentClient.Requests.RequestsBehaviour

  @impl true
  def get(url) do
    {:ok,
     %Tesla.Env{
       method: :get,
       url: url,
       status: 200,
       body:
         Bento.encode!(%{
           "interval" => 900,
           "peers" => Utils.generate_n_peers(5)
         })
     }}
  end
end
