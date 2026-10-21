defmodule TorrentClient.WebseedHttpBehaviour do
  @moduledoc """
  HTTP edge for webseed (BEP-19) Range fetches. Tests substitute
  `TorrentClient.WebseedHttpMock`; production uses
  `TorrentClient.WebseedHttpClient`.
  """

  @doc "GET `url` with request `headers`; Range responses carry the slice."
  @callback get(url :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, Tesla.Env.t()} | {:error, term()}
end
