# Manual smoke helper, kept out of application code.
# Usage: mix run scripts/test_run.exs [torrent_file] [download_dir]
#
# Exercises the real pipeline end to end; every section prints ok=true and
# the script raises on the first mismatch:
#   1. parse the torrent and hash the as-found info dict
#   2. disk layout for the real torrent
#   3. HTTP tracker peer fetch (tolerates unreachable trackers)
#      + event/key URL sample
#   4. announce_all fan-out with stub queries (offline, deterministic)
#   5. UDP tracker codec over loopback :gen_udp (offline)
#   6. peer address validation: literal parse, usability filter, ports
#   7. coordinator-driven 3-piece download against 2 loopback seeds
#   8. watchdog stall -> :download_stalled report (offline)
#   9. resume codec round-trip with the actually-verified pieces
require Logger

defmodule SmokeSeed do
  @moduledoc false
  @seed_id String.duplicate("S", 20)

  def recv_frame(sock) do
    with {:ok, <<length::32-big>>} <- :gen_tcp.recv(sock, 4, 5_000),
         {:ok, payload} <- :gen_tcp.recv(sock, length, 5_000) do
      PeerMessage.decode(<<length::32-big, payload::binary>>)
    end
  end

  def send_message(sock, message) do
    {:ok, bytes} = PeerMessage.encode(message)
    :ok = :gen_tcp.send(sock, bytes)
  end

  def greet(sock, info_hash, bits) do
    {:ok, bytes} = :gen_tcp.recv(sock, 68, 5_000)
    {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(bytes)
    :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @seed_id) |> Handshake.serialize())
    {:ok, %PeerMessage.Interested{}, <<>>} = recv_frame(sock)
    {:ok, %PeerMessage.Unchoke{}, <<>>} = recv_frame(sock)
    send_message(sock, %PeerMessage.Bitfield{bits: bits})
    send_message(sock, %PeerMessage.Unchoke{})
  end

  # Loop forever: the coordinator dials, redials, and duplicates across
  # these listeners for the whole download.
  def accept_loop(listen, info_hash, data, bits) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        spawn(fn ->
          greet(sock, info_hash, bits)
          serve_all(sock, data)
        end)

        accept_loop(listen, info_hash, data, bits)

      {:error, _} ->
        :ok
    end
  end

  def serve_all(sock, data) do
    case recv_frame(sock) do
      {:ok, %PeerMessage.Request{index: index, begin: begin, length: length}, <<>>} ->
        send_message(sock, %PeerMessage.Piece{
          index: index,
          begin: begin,
          block: binary_part(Enum.at(data, index), begin, length)
        })

        serve_all(sock, data)

      {:ok, %PeerMessage.Cancel{}, _} ->
        serve_all(sock, data)

      {:error, _} ->
        :ok
    end
  end

  def listen! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end
end

args = System.argv()
torrent_filename = Enum.at(args, 0, "test/_data/debian-12.1.0-amd64-netinst.iso.torrent")
download_dir = Enum.at(args, 1, Path.join(System.tmp_dir!(), "smoke"))

unless File.exists?(torrent_filename) do
  raise "torrent file not found: #{torrent_filename}"
end

# 1. Parse the torrent and hash the as-found info dict.
{:ok, torrent_bytes} = File.read(torrent_filename)
{:ok, bento, info} = Torrent.parse_bytes(torrent_bytes)
info_hash = Torrent.info_hash(info)
Logger.info("info_hash=#{info_hash} pieces=#{length(Torrent.get_piece_hashes(bento))}")

# 2. Prepare the download layout (validated paths, declared sizes).
:ok = TorrentClient.Disk.init_layout(download_dir, bento.info)
Logger.info("layout ready under #{download_dir}")

# 3. Ask trackers for peers (bounded fan-out; tolerates unreachable
# trackers), plus the event/key parameters trackers need on started
# announces.
peer_id = Utils.generate_peer_id()

# query_once dispatches UDP vs HTTP(S) per URL so mixed tiers work.
query = fn url ->
  TorrentClient.Announcer.query_once(url,
    bento: bento,
    info_hash: info_hash,
    peer_id: peer_id,
    port: 6881
  )
end

tracker_urls = bento |> Torrent.announce_tiers() |> List.flatten()

peers =
  case TorrentClient.Announcer.announce_all(tracker_urls, query, timeout: 10_000) do
    {:ok, %{peers: peers}} -> peers
    {:error, _} -> []
  end

Logger.info("peers=#{length(peers)}#{if peers == [], do: " (trackers unreachable?)", else: ""}")

if first = List.first(peers),
  do: Logger.info("first peer=#{inspect(Map.take(first, [:ip_tuple, :port]))}")

# (event/key sample for started announces)
sample_url =
  Tracker.tracker_url(bento.announce, bento, info_hash, Utils.generate_peer_id(), 6881,
    event: "started",
    key: "12345"
  )

true = String.contains?(sample_url, "event=started") and String.contains?(sample_url, "key=12345")
Logger.info("event/key url ok=true")

# 4. announce_all fan-out with stub queries: one success, one error, one
# raise (a raising query must fail like a dead tracker, not take us down).
fanout_query = fn
  "http://ok/" -> {:ok, %{peers: [%Peer{ip_tuple: {1, 2, 3, 4}, port: 6881}], interval: 900}}
  "http://dead/" -> {:error, :timeout}
  "http://boom/" -> raise "kaboom"
end

{:ok, %{peers: merged, interval: 900}} =
  TorrentClient.Announcer.announce_all(
    ["http://ok/", "http://dead/", "http://boom/"],
    fanout_query,
    timeout: 2_000
  )

true = merged == [%Peer{ip_tuple: {1, 2, 3, 4}, port: 6881}]
Logger.info("announce fan-out ok=true")

# 5. UDP tracker codec over loopback: encode/decode plus the real
# transport, no internet.
parent = self()

spawn(fn ->
  {:ok, srv} = :gen_udp.open(0, [:binary, active: false])
  {:ok, udp_port} = :inet.port(srv)
  send(parent, {:udp_port, udp_port})

  {:ok, {host, cli_port, connect_req}} = :gen_udp.recv(srv, 0, 5_000)
  <<0x41727101980::64-big, 0::32-big, xid::32-big>> = connect_req
  {:ok, connect_resp} = TorrentClient.UdpTracker.encode_connect_response(xid, 0x1234)
  :ok = :gen_udp.send(srv, host, cli_port, connect_resp)

  # Reply to THIS packet's sender: the client uses a fresh socket per
  # exchange, like real trackers expect.
  {:ok, {host2, cli_port2, announce_req}} = :gen_udp.recv(srv, 0, 5_000)
  <<_conn::64-big, 1::32-big, axid::32-big, _rest::binary>> = announce_req

  {:ok, announce_resp} =
    TorrentClient.UdpTracker.encode_announce_response(axid, 900, 0, 1, <<10, 0, 0, 9, 26, 225>>)

  :ok = :gen_udp.send(srv, host2, cli_port2, announce_resp)
end)

udp_port =
  receive do
    {:udp_port, p} -> p
  after
    5_000 -> raise "udp stub did not start"
  end

{:ok, connect_req} = TorrentClient.UdpTracker.encode_connect(0xCAFE)

{:ok, %{data: connect_raw, family: :inet}} =
  TorrentClient.Udp.send_recv("127.0.0.1", udp_port, connect_req, 2_000)

{:ok, %{connection_id: conn_id}} = TorrentClient.UdpTracker.decode_connect(connect_raw, 0xCAFE)

{:ok, announce_req} =
  TorrentClient.UdpTracker.encode_announce(%{
    connection_id: conn_id,
    transaction_id: 0xBEEF,
    info_hash: :crypto.strong_rand_bytes(20),
    peer_id: String.duplicate("Q", 20),
    downloaded: 0,
    left: 100,
    uploaded: 0,
    event: 2,
    ip: 0,
    key: 1,
    num_want: -1,
    port: 6881
  })

{:ok, %{data: announce_raw}} =
  TorrentClient.Udp.send_recv("127.0.0.1", udp_port, announce_req, 2_000)

{:ok, %{peers: raw_peers}} = TorrentClient.UdpTracker.decode_announce(announce_raw, 0xBEEF, :ipv4)
{:ok, [%Peer{ip_tuple: {10, 0, 0, 9}, port: 6881}]} = Peer.parse_compact(raw_peers, :ipv4)
Logger.info("udp tracker round-trip ok=true")

# 6. Peer address validation: literal-only parse (full, compressed,
# mapped), usability filter drops, and port-range rejection.
{:ok, {1, 2, 3, 4}} = Peer.parse_address("1.2.3.4")
{:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}} = Peer.parse_address("2001:db8::1")
{:ok, {0, 0, 0, 0, 0, 0xFFFF, _, _}} = Peer.parse_address("::ffff:1.2.3.4")
{:error, :unparseable_peer_address} = Peer.parse_address("tracker.example.com")
true = Peer.usable?(%Peer{ip_tuple: {8, 8, 8, 8}, port: 6881})
false = Peer.usable?(%Peer{ip_tuple: {127, 0, 0, 1}, port: 6881})
false = Peer.usable?(%Peer{ip_tuple: {0, 0, 0, 0}, port: 6881})
false = Peer.usable?(%Peer{ip_tuple: {8, 8, 8, 8}, port: 0})
# Compact dict round-trip through the real tracker parser: the loopback
# entry survives, the unusable ones are dropped, bad ports reject all.
mixed_body =
  Bento.encode!(%{
    "interval" => 60,
    "peers" => <<1, 2, 3, 4, 0x1A, 0xE1, 127, 0, 0, 1, 0x1A, 0xE1>>
  })

{:ok, %{peers: [%Peer{ip_tuple: {1, 2, 3, 4}, port: 6881}]}} =
  Tracker.parse_peer_response(mixed_body)

bad_port_body = Bento.encode!(%{"peers" => [%{"ip" => "1.2.3.4", "port" => 0}]})
{:error, _} = Tracker.parse_peer_response(bad_port_body)
Logger.info("address validation ok=true")

# 7. Coordinator-driven 3-piece download against 2 loopback seeds.
# Each piece is 2 blocks so the 5-wide request pipeline actually runs.
coord_info = %{:"piece length" => 32_768, name: "smoke-coord.bin", length: 3 * 32_768}
coord_data = for _ <- 1..3, do: :crypto.strong_rand_bytes(32_768)
coord_hashes = Enum.map(coord_data, &:crypto.hash(:sha, &1))
# Raw 20 bytes on the wire: the coordinator/worker layer takes raw
# hashes (see tests); hex is only for tracker URLs and logging.
coord_hash = :crypto.strong_rand_bytes(20)
coord_dir = Path.join(download_dir, "smoke-coord")
:ok = TorrentClient.Disk.init_layout(coord_dir, coord_info)

{listen1, coord_port1} = SmokeSeed.listen!()
{listen2, coord_port2} = SmokeSeed.listen!()

for listen <- [listen1, listen2] do
  spawn(fn -> SmokeSeed.accept_loop(listen, coord_hash, coord_data, <<0b11100000>>) end)
end

{:ok, coord_sup} =
  TorrentClient.TorrentSupervisor.start_link(
    info_hash: coord_hash,
    peers: [
      %Peer{ip_tuple: {127, 0, 0, 1}, port: coord_port1},
      %Peer{ip_tuple: {127, 0, 0, 1}, port: coord_port2}
    ],
    info: coord_info,
    piece_hashes: coord_hashes,
    base_dir: coord_dir,
    peer_id: Utils.generate_peer_id(),
    report_to: self(),
    recv_timeout: 2_000,
    piece_timeout: 10_000,
    watchdog_timeout: 10_000
  )

[{coord_pid, _}] = Registry.lookup(TorrentClient.Registry, {coord_hash, :coordinator})
coord_ref = Process.monitor(coord_pid)

receive do
  {:torrent_complete, ^coord_hash} -> :ok
after
  30_000 -> raise "coordinator did not finish"
end

receive do
  {:DOWN, ^coord_ref, :process, ^coord_pid, :normal} -> :ok
after
  5_000 -> raise "coordinator did not stop"
end

for {data, index} <- Enum.with_index(coord_data) do
  {:ok, ^data} = TorrentClient.Disk.read_piece(coord_dir, coord_info, index)
end

Logger.info("coordinator download ok=true")
Supervisor.stop(coord_sup)

# 8. Watchdog stall reports instead of hanging: silent seed, no blocks.
{listen_s, stall_port} = SmokeSeed.listen!()
stall_hash = :crypto.strong_rand_bytes(20)

spawn(fn ->
  {:ok, sock} = :gen_tcp.accept(listen_s, 5_000)
  SmokeSeed.greet(sock, stall_hash, <<0b11100000>>)
  :gen_tcp.recv(sock, 0, 30_000)
end)

{:ok, stall_sup} =
  TorrentClient.TorrentSupervisor.start_link(
    info_hash: stall_hash,
    peers: [%Peer{ip_tuple: {127, 0, 0, 1}, port: stall_port}],
    info: coord_info,
    piece_hashes: coord_hashes,
    base_dir: Path.join(download_dir, "smoke-stall"),
    peer_id: Utils.generate_peer_id(),
    report_to: self(),
    recv_timeout: 2_000,
    piece_timeout: 30_000,
    watchdog_timeout: 100,
    max_stalls: 0
  )

receive do
  {:download_stalled, _} -> :ok
after
  10_000 -> raise "watchdog did not fire"
end

Logger.info("watchdog give-up ok=true")
Supervisor.stop(stall_sup)

# 9. Resume codec round-trip with the actually-verified pieces.
resume = %{
  info_hash: coord_hash,
  verified: MapSet.new([0, 1, 2]),
  total: 3,
  piece_length: 32_768
}

{:ok, encoded} = TorrentClient.Disk.encode_resume(resume)
resume_path = Path.join(download_dir, "resume.bin")
:ok = TorrentClient.Disk.write(resume_path, encoded)
{:ok, stored} = TorrentClient.Disk.read(resume_path)
{:ok, decoded} = TorrentClient.Disk.decode_resume(stored)

true =
  decoded == %{info_hash: resume.info_hash, verified: [0, 1, 2], total: 3, piece_length: 32_768}

Logger.info("resume round-trip ok=true")
