defmodule TorrentClient.Requests.RequestsBehaviour do
  @moduledoc """
  Tracker HTTP seam; tests substitute `TorrentClient.Requests.RequestsMock`.
  """

  @doc "Execute a GET request"
  @callback get(binary()) :: {:error, any()} | {:ok, Tesla.Env.t()}
end
