defmodule TorrentClient.Requests.RequestsBehaviour do
  @doc "Execute a GET request"
  @callback get(binary()) :: {:error, any()} | {:ok, Tesla.Env.t()}
end
