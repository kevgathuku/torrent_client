# Manual smoke helper, kept out of application code.
# Usage: mix run scripts/test_run.exs [torrent_file] [download_dir]
#
# Exercises the real pipeline: parse -> info-hash -> disk layout ->
# tracker peer fetch -> resume codec round-trip. The peer fetch hits the
# network; everything else is local. Exits 0 even when trackers are
# unreachable (prints what happened instead of crashing).
require Logger

[torrent_filename, download_dir | _] =
  System.argv() ++
    ["test/_data/debian-12.1.0-amd64-netinst.iso.torrent", Path.join(System.tmp_dir!(), "smoke")]

unless File.exists?(torrent_filename) do
  raise "torrent file not found: #{torrent_filename}"
end

# 1. Parse the torrent and hash the as-found info dict.
{:ok, bento, info} = Downloader.parse_torrent_file(torrent_filename)
info_hash = Torrent.info_hash(info)
Logger.info("info_hash=#{info_hash} pieces=#{length(Torrent.get_piece_hashes(bento))}")

# 2. Prepare the download layout (validated paths, declared sizes).
:ok = TorrentClient.Disk.init_layout(download_dir, bento.info)
Logger.info("layout ready under #{download_dir}")

# 3. Ask trackers for peers (async inside the server; poll briefly).
{:ok, pid} = Downloader.start_link(torrent_filename)

peers =
  Enum.reduce_while(1..15, [], fn _, _ ->
    case :sys.get_state(pid).peers do
      [] -> Process.sleep(1_000) && {:cont, []}
      peers -> {:halt, peers}
    end
  end)

Logger.info("peers=#{length(peers)}#{if peers == [], do: " (trackers unreachable?)", else: ""}")
if first = List.first(peers), do: Logger.info("first peer=#{inspect(Map.take(first, [:ip_tuple, :port]))}")

# 4. Pause/resume codec round-trip through the real disk seam.
resume = %{info_hash: Utils.sha_sum("smoke"), verified: MapSet.new(), total: 1, piece_length: 1}
{:ok, encoded} = TorrentClient.Disk.encode_resume(resume)
resume_path = Path.join(download_dir, "resume.bin")
:ok = TorrentClient.Disk.write(resume_path, encoded)
{:ok, stored} = TorrentClient.Disk.read(resume_path)
{:ok, decoded} = TorrentClient.Disk.decode_resume(stored)
Logger.info("resume round-trip ok=#{decoded == %{resume | verified: []}}")

Downloader.stop(pid)
