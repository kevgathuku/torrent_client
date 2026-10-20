defmodule TrackerTest do
  use ExUnit.Case, async: true

  import Mox

  @port 6881
  @peer_id Utils.generate_peer_id()

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

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
    assert Application.get_env(:torrent_client, :requests_impl) ==
             TorrentClient.Requests.RequestsMock
  end

  @tag torrent_file: TestHelpers.multi_file_torrent()
  test "builds valid tracker url", %{bento_torrent: bento_torrent, tracker_url: tracker_url} do
    assert String.contains?(tracker_url, bento_torrent.announce)
    assert String.contains?(tracker_url, URI.encode_query(%{peer_id: @peer_id}))
    assert String.contains?(tracker_url, to_string(@port))
  end

  @tag torrent_file: TestHelpers.multi_file_torrent()
  test "parses valid tracker response correctly", %{tracker_url: tracker_url} do
    # Returns parsed list of peers
    assert {:ok, %{peers: peers}} = TorrentClient.Requests.Client.get_peers(tracker_url)

    assert length(peers) == 5
    assert Enum.all?(peers, fn peer -> peer.__struct__ == Peer end) == true
  end
end
