defmodule TorrentClient.AnnouncerTest do
  @moduledoc """
  The re-announce worker against doubles, zero real I/O. Uses manjaro's real
  UDP tier URL with manjaro's info-hash (ubuntu carries no UDP tier).
  """
  use ExUnit.Case, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :capture_log

  defp manjaro do
    {:ok, bento, info} =
      Downloader.parse_torrent_file("test/_data/manjaro-gnome-17.1.9-stable-x86_64.torrent")

    %{bento: bento, info_hash: Torrent.info_hash(info)}
  end

  defp udp_url do
    %{bento: bento} = manjaro()

    [tier | _] =
      Torrent.announce_tiers(bento)
      |> Enum.filter(fn urls -> Enum.any?(urls, &String.starts_with?(&1, "udp://")) end)

    [url | _] = tier
    url
  end

  defp start_worker(extra_opts \\ []) do
    %{bento: bento, info_hash: info_hash} = manjaro()

    opts =
      Keyword.merge(
        [
          bento: bento,
          info_hash: info_hash,
          peer_id: String.duplicate("p", 20),
          port: 6881,
          tracker_url: udp_url(),
          interval_ms: 50,
          udp: TorrentClient.UdpMock
        ],
        extra_opts
      )

    start_supervised!({TorrentClient.Announcer, opts})
  end

  defp stub_transport(test_pid, peers, family \\ :inet, interval \\ 0) do
    TorrentClient.UdpMock
    |> stub(:send_recv, fn
      _host, _port, <<0x41727101980::64-big, _action::32-big, xid::32-big>>, _timeout ->
        {:ok, %{family: family, data: <<0::32-big, xid::32-big, 0x1234::64-big>>}}

      _host, _port, <<_conn::64-big, _action::32-big, xid::32-big, _rest::binary>>, _timeout ->
        send(test_pid, :announced)

        {:ok,
         %{
           family: family,
           data: <<1::32-big, xid::32-big, interval::32-big, 0::32-big, 1::32-big, peers::binary>>
         }}
    end)
  end

  test "dry swarm re-announces on interval" do
    stub_transport(self(), <<>>)
    pid = start_worker()

    assert_receive :announced, 1_000
    assert_receive :announced, 1_000
    assert %{peers: []} = :sys.get_state(pid)
  end

  test "returned peers land in state" do
    stub_transport(self(), <<192, 168, 1, 1, 0x1F, 0x90>>)
    pid = start_worker()

    assert_receive :announced, 1_000
    assert %{peers: [%Peer{ip_tuple: {192, 168, 1, 1}, port: 8080}]} = :sys.get_state(pid)
  end

  test "ipv6 peers land in state" do
    peers = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x1F, 0x90>>
    stub_transport(self(), peers, :inet6)
    pid = start_worker()

    assert_receive :announced, 1_000

    assert %{peers: [%Peer{ip_tuple: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, port: 8080}]} =
             :sys.get_state(pid)
  end

  test "http tiers announce through the requests seam" do
    stub_transport(self(), <<>>)

    %{bento: bento, info_hash: info_hash} = manjaro()
    [http_url | _] = Torrent.announce_tiers(bento) |> hd()

    pid =
      start_supervised!(
        {TorrentClient.Announcer,
         [
           bento: bento,
           info_hash: info_hash,
           peer_id: String.duplicate("p", 20),
           port: 6881,
           tracker_url: http_url,
           interval_ms: 50,
           udp: TorrentClient.UdpMock
         ]}
      )

    Process.sleep(100)
    assert %{peers: peers} = :sys.get_state(pid)
    assert length(peers) == 5
  end

  test "tiers come from the torrent when no override is given" do
    stub_transport(self(), <<>>)
    %{bento: bento, info_hash: info_hash} = manjaro()

    pid =
      start_supervised!(
        {TorrentClient.Announcer,
         [
           bento: bento,
           info_hash: info_hash,
           peer_id: String.duplicate("p", 20),
           port: 6881,
           interval_ms: 50,
           udp: TorrentClient.UdpMock
         ]}
      )

    Process.sleep(100)
    # Tier 1 is HTTP (requests seam mock returns 5 peers); UDP tier never dialed.
    assert %{peers: peers} = :sys.get_state(pid)
    assert length(peers) == 5
  end

  test "tracker interval stretches the re-announce delay" do
    stub_transport(self(), <<>>, :inet, 3600)
    start_worker()

    assert_receive :announced, 1_000
    refute_receive :announced, 200
  end

  test "exhausted tiers reset for the next cycle" do
    stub_transport(self(), <<>>)
    pid = start_worker(tracker_url: "ftp://example.com/announce")

    Process.sleep(150)
    assert Process.alive?(pid)
    assert %{peers: []} = :sys.get_state(pid)
  end

  test "supervised worker restarts after a crash" do
    stub_transport(self(), <<>>)
    key = {:announcer, System.unique_integer([:positive])}
    pid = start_worker(name: {:via, Registry, {TorrentClient.Registry, key}})

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    restarted =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Registry.lookup(TorrentClient.Registry, key) do
          [{new_pid, _}] when new_pid != pid and is_pid(new_pid) ->
            if Process.alive?(new_pid), do: {:halt, new_pid}, else: {:cont, nil}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    assert is_pid(restarted)
  end
end
