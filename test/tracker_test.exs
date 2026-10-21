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

    test "accepts boundary ports and rejects out-of-range ports" do
      response = fn port ->
        Tracker.parse_peer_response(
          Bento.encode!(%{"peers" => [%{"ip" => "1.2.3.4", "port" => port}]})
        )
      end

      assert {:ok, %{peers: [%Peer{port: 1}]}} = response.(1)
      assert {:ok, %{peers: [%Peer{port: 65_535}]}} = response.(65_535)

      for port <- [0, -1, 65_536] do
        assert {:error, _} = response.(port), "port #{port} must be rejected"
      end
    end

    test "drops unusable addresses instead of returning them" do
      body =
        Bento.encode!(%{
          "interval" => 900,
          "peers" => [
            %{"ip" => "1.2.3.4", "port" => 6881},
            %{"ip" => "127.0.0.1", "port" => 6881},
            %{"ip" => "224.0.0.1", "port" => 6881},
            %{"ip" => "::1", "port" => 6881},
            %{"ip" => "2001:db8::1", "port" => 6881}
          ]
        })

      assert {:ok, %{peers: peers}} = Tracker.parse_peer_response(body)

      assert peers == [
               %Peer{ip_tuple: {1, 2, 3, 4}, port: 6881},
               %Peer{ip_tuple: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, port: 6881}
             ]
    end

    test "drops unusable compact peers" do
      body =
        Bento.encode!(%{
          "interval" => 900,
          "peers" => <<1, 2, 3, 4, 0x1A, 0xE1, 0, 0, 0, 0, 0x1A, 0xE1, 5, 6, 7, 8, 0, 0>>
        })

      assert {:ok, %{peers: peers}} = Tracker.parse_peer_response(body)
      assert peers == [%Peer{ip_tuple: {1, 2, 3, 4}, port: 6881}]
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

    test "event and key ride along when given" do
      {:ok, bento, _info} = TestHelpers.single_file_torrent() |> Downloader.parse_torrent_file()

      url =
        Tracker.tracker_url(bento.announce, bento, Base.encode16(<<1>>), "peer", 6881,
          event: "started",
          key: "42"
        )

      assert String.contains?(url, "event=started")
      assert String.contains?(url, "key=42")
    end

    test "event and key are absent by default" do
      {:ok, bento, _info} = TestHelpers.single_file_torrent() |> Downloader.parse_torrent_file()
      url = Tracker.tracker_url(bento.announce, bento, Base.encode16(<<1>>), "peer", 6881)

      refute String.contains?(url, "event=")
      refute String.contains?(url, "key=")
    end
  end

  describe "hostile responses" do
    test "garbage bytes are an error, not a crash" do
      assert {:error, _} = Tracker.parse_peer_response(<<0xFF, 0x00, 0xDE, 0xAD>>)
    end
  end
end
