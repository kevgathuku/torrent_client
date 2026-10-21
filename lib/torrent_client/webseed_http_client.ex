defmodule TorrentClient.WebseedHttpClient do
  @moduledoc """
  Real webseed HTTP implementation via Tesla.

  Follows up to 3 redirects: archive.org answers `/download/` URLs
  with a 302 to a backend host, so a no-redirect fetch would never
  reach the bytes. Range headers survive the redirect; auth headers
  are stripped per the middleware.
  """

  @behaviour TorrentClient.WebseedHttpBehaviour

  @impl true
  def get(url, headers) do
    Tesla.get(client(), url, headers: headers)
  end

  defp client do
    Tesla.client(
      [{Tesla.Middleware.FollowRedirects, max_redirects: 3}],
      Tesla.Adapter.Hackney
    )
  end
end
