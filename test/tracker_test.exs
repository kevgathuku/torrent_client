defmodule TrackerTest do
  use ExUnit.Case, async: true

  import Mox

  @port 6881
  @peer_id Utils.generate_peer_id()

  setup context do
    case context do
      # If torrent_file_path is available in the context
      %{torrent_file: torrent_file} ->
        {:ok, bento_torrent} = Downloader.parse_torrent_file(torrent_file)
        tracker_url = Tracker.tracker_url(bento_torrent, @peer_id, @port)
        # Context to be available to tests
        %{bento_torrent: bento_torrent, tracker_url: tracker_url}

      _ ->
        # Return :ok when we don't want to add any extra metadata
        :ok
    end
  end

  test "returns mock client when in test env" do
    assert Application.get_env(:torrent_client, :requests_impl) == TorrentClient.Requests.Mock
  end

  @tag torrent_file: Utils.multi_file_torrent()
  test "builds valid tracker url", %{bento_torrent: bento_torrent, tracker_url: tracker_url} do
    assert String.contains?(tracker_url, bento_torrent.announce)
    assert String.contains?(tracker_url, URI.encode_query(%{peer_id: @peer_id}))
    assert String.contains?(tracker_url, to_string(@port))
  end

  @tag torrent_file: Utils.multi_file_torrent()
  test "parses valid tracker response correctly", %{tracker_url: tracker_url} do
    TorrentClient.Requests.Mock
    |> expect(:get, fn _url ->
      {:ok,
       %Tesla.Env{
         status: 200,
         body:
           Bento.encode!(%{
             "interval" => 900,
             "peers" => Utils.generate_n_peers(5)
           })
       }}
    end)

    # Returns parsed list of peers
    assert {:ok, %{peers: peers}} = Tracker.get_peers(tracker_url)

    assert length(peers) == 5
    assert Enum.all?(peers, fn peer -> peer.__struct__ == Peer end) == true
  end
end
