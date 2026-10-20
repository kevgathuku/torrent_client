defmodule TorrentClient.Requests.Client do
  @moduledoc """
  HTTP edge for tracker requests. Dispatches to the configured impl;
  pure response parsing lives in `Tracker`.
  """

  def get(args) do
    impl().get(args)
  end

  @doc """
  Request the peers from the tracker URL. Pure parsing of the response
  lives in `Tracker.parse_peer_response/1`.
  """
  def get_peers(tracker_url) do
    case get(tracker_url) do
      {:ok, %{body: body}} ->
        Tracker.parse_peer_response(body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Chooses which impl to use at runtime
  defp impl do
    Application.get_env(:torrent_client, :requests_impl)
  end
end
