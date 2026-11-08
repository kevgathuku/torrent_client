# Manual smoke helper, kept out of application code.
# Usage: mix run scripts/test_run.exs [torrent_file] [download_dir]
#
# Exercises the real pipeline end to end against the real swarm; every
# section prints ok=true and the script raises on the first mismatch:
#   1. parse the torrent and hash the as-found info dict
#   2. disk layout for the real torrent
#   3. peer fetch from the real trackers
#   4. download piece 0 from real peers (rest pre-marked via resume)
require Logger

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

# 3. Ask the real trackers for real peers.
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

# 4. Real download from real peers: fetch piece 0 of the real torrent.
# The rest is pre-marked verified through the resume seam, so this is
# shaped like resuming a nearly-complete torrent — one piece over the
# wire, fully connected, handshaked, requested in blocks, SHA1-verified,
# and written to the §2 layout. No loopback seeds, no synthetic bytes.
hashes = Torrent.get_piece_hashes(bento)
true = is_list(hashes) and length(hashes) > 0

if peers == [] do
  raise "no peers from trackers; cannot smoke-test a real download"
end

# The coordinator takes the raw 20 bytes; hex is only for URLs/logging.
raw_hash = Base.decode16!(info_hash)
[first_hash | _] = hashes
total = length(hashes)
already = if total > 1, do: Enum.to_list(1..(total - 1)), else: []

{:ok, sup} =
  TorrentClient.TorrentSupervisor.start_link(
    info_hash: raw_hash,
    peers: peers,
    info: bento.info,
    piece_hashes: hashes,
    verified: already,
    base_dir: download_dir,
    peer_id: peer_id,
    report_to: self(),
    recv_timeout: 10_000,
    piece_timeout: 120_000,
    watchdog_timeout: 60_000
  )

[{coord_pid, _}] = Registry.lookup(TorrentClient.Registry, {raw_hash, :coordinator})
coord_ref = Process.monitor(coord_pid)

receive do
  {:torrent_complete, ^raw_hash} -> :ok
after
  300_000 -> raise "real download did not finish piece 0"
end

receive do
  {:DOWN, ^coord_ref, :process, ^coord_pid, :normal} -> :ok
after
  5_000 -> raise "coordinator did not stop"
end

{:ok, piece0} = TorrentClient.Disk.read_piece(download_dir, bento.info, 0)
true = Torrent.verify_hash?(piece0, first_hash)

Logger.info("real download ok=true")
Supervisor.stop(sup)
