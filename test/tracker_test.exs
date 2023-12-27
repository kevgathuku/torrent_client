defmodule TrackerTest do
  use ExUnit.Case

  @port 6881
  @peer_id Utils.generate_peer_id()

  setup do
    # TODO: Return correctly encoded tracker response
    Tesla.Mock.mock(fn
      %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body: %{
            response: "other"
          }
        }
    end)

    :ok
  end

  setup context do
    case context do
      # If torrent_file_path is available in the context
      %{torrent_file: torrent_file} ->
        {:ok, bento_torrent} = Downloader.parse_torrent_file(torrent_file)
        tracker_url = Tracker.tracker_url(bento_torrent, @peer_id, @port)
        # Context to be available to tests
        %{bento_torrent: bento_torrent, tracker_url: tracker_url}

      _ ->
        # We can simply return :ok when we don't want to add any extra metadata
        :ok
    end
  end

  test "returns mock client when in test env" do
    assert Application.get_env(:tesla, :adapter) == Tesla.Mock
  end

  @tag torrent_file: Utils.multi_file_torrent()
  test "builds valid tracker url", %{bento_torrent: bento_torrent, tracker_url: tracker_url} do
    assert String.contains?(tracker_url, bento_torrent.announce)
    assert String.contains?(tracker_url, URI.encode_query(%{peer_id: @peer_id}))
    assert String.contains?(tracker_url, to_string(@port))
  end

  @tag torrent_file: Utils.multi_file_torrent()
  test "parses tracker response correctly", %{tracker_url: tracker_url} do
    assert {:ok, env} = Tracker.get_peers(tracker_url)
    assert env.status == 200
    assert env.body == "hello"
  end
end
