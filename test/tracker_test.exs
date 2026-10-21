defmodule TrackerTest do
  use ExUnit.Case, async: true

  import Mox

  alias TorrentClient.Requests.Client, as: RequestsClient

  @port 6881
  @peer_id Utils.generate_peer_id()

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  setup context do
    case context do
      # If torrent_file_path is available in the context
      %{torrent_file: torrent_file} ->
        {:ok, bento_torrent, info} = Downloader.parse_torrent_file(torrent_file)
        info_hash = Torrent.info_hash(info)

        tracker_url =
          Tracker.tracker_url(bento_torrent.announce, bento_torrent, info_hash, @peer_id, @port)

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
    assert {:ok, %{peers: peers}} = RequestsClient.get_peers(tracker_url)

    assert length(peers) == 5
    assert Enum.all?(peers, fn peer -> peer.__struct__ == Peer end) == true
  end

  describe "dictionary-model peers" do
    test "parses a non-compact peer list" do
      body =
        Bento.encode!(%{
          "interval" => 900,
          "peers" => [
            %{"ip" => "1.2.3.4", "port" => 6881},
            %{"ip" => "10.0.0.1", "port" => 51_413, "peer id" => String.duplicate("a", 20)}
          ]
        })

      assert {:ok, %{peers: peers}} = Tracker.parse_peer_response(body)

      assert peers == [
               %Peer{ip_tuple: {1, 2, 3, 4}, port: 6881},
               %Peer{ip_tuple: {10, 0, 0, 1}, port: 51_413}
             ]
    end

    test "rejects entries with unparseable addresses" do
      body = Bento.encode!(%{"peers" => [%{"ip" => "not-an-ip", "port" => 6881}]})
      assert {:error, _} = Tracker.parse_peer_response(body)
    end

    test "rejects entries with non-integer ports" do
      body = Bento.encode!(%{"peers" => [%{"ip" => "1.2.3.4", "port" => "6881"}]})
      assert {:error, _} = Tracker.parse_peer_response(body)
    end
  end

  describe "tracker_url encoding" do
    test "binary info_hash is percent-encoded byte-wise, never space-as-plus" do
      {:ok, bento, _info} = TestHelpers.single_file_torrent() |> Downloader.parse_torrent_file()
      # 0x20 must become %20, not +
      url =
        Tracker.tracker_url(bento.announce, bento, Base.encode16(<<0x20, 0xFF>>), "peer", 6881)

      assert String.contains?(url, "h=%20%FF")
      refute String.contains?(url, "h=+")
    end
  end
end
