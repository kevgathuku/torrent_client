defmodule TorrentClient.Requests.Client do
  def get(args) do
    impl().get(args)
  end

  # Chooses which impl to use at runtime
  defp impl do
    Application.get_env(:torrent_client, :requests_impl)
  end
end
