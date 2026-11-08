# Manual smoke helper, kept out of application code.
# Usage: mix run scripts/test_run.exs [torrent_file] [download_dir]
#
# Exercises the real pipeline end to end through the real Session — the
# same calls a client makes: add -> tracker announce -> supervised
# subtree download -> verify. Every section prints ok=true and the script
# raises on the first mismatch:
#   1. parse the torrent (logging and post-download verification only)
#   2. add to the session and wait for completion
#   3. verify every piece on disk against the real piece hashes
require Logger

args = System.argv()
torrent_filename = Enum.at(args, 0, "test/_data/debian-12.1.0-amd64-netinst.iso.torrent")
download_dir = Enum.at(args, 1, Path.join(System.tmp_dir!(), "smoke"))

unless File.exists?(torrent_filename) do
  raise "torrent file not found: #{torrent_filename}"
end

# 1. Parse the torrent. The session parses it again on add; this copy is
# only for logging and for the post-download spot check.
{:ok, torrent_bytes} = File.read(torrent_filename)
{:ok, bento, info} = Torrent.parse_bytes(torrent_bytes)
info_hash = Torrent.info_hash(info)
hashes = Torrent.get_piece_hashes(bento)
true = is_list(hashes) and length(hashes) > 0
Logger.info("info_hash=#{info_hash} pieces=#{length(hashes)}")

# 2. Add to the real session: it announces to the real trackers, starts
# the supervised subtree (peers, refill, webseeds), and downloads.
# A previous run's entry is forgotten first so the smoke always starts
# from add; bytes and resume state on disk survive and resume as usual.
for %{id: id, path: path} <- TorrentClient.Session.status(),
    Path.expand(path) == Path.expand(torrent_filename) do
  {:ok, ^id} = TorrentClient.Session.forget(id)
end

{:ok, hex} = TorrentClient.Session.add_torrent(torrent_filename, base_dir: download_dir)

# Live progress comes from the published resume file, not the session
# entry: the coordinator rewrites it on every verified piece, while the
# entry's counter only moves on the terminal report.
raw = Base.decode16!(info_hash)
total = length(hashes)

progress = fn ->
  TorrentClient.Disk.load_verified(TorrentClient.Disk, download_dir, %{
    info_hash: raw,
    total: total,
    piece_length: Map.get(bento.info, :"piece length")
  })
  |> length()
end

wait_for = fn wait_for, deadline ->
  entry = Enum.find(TorrentClient.Session.status(), &(&1.id == hex))

  cond do
    entry == nil ->
      raise "session entry vanished"

    entry.status == :complete ->
      Logger.info("complete #{progress.()}/#{total}")
      :ok

    entry.status in [:exhausted, :stalled] ->
      raise "download ended #{entry.status}: #{progress.()}/#{total} verified"

    System.monotonic_time(:second) > deadline ->
      raise "timed out waiting: #{entry.status} #{progress.()}/#{total} verified"

    true ->
      Logger.info("... #{entry.status} #{progress.()}/#{total}")
      Process.sleep(15_000)
      wait_for.(wait_for, deadline)
  end
end

wait_for.(wait_for, System.monotonic_time(:second) + 1_800)
Logger.info("real download ok=true")

# 3. Validate the complete download: every piece on disk must match its
# real hash. A stale resume file can mark the torrent complete without
# the bytes being present, so trust hashes, not status.
bad =
  hashes
  |> Enum.with_index()
  |> Enum.reduce([], fn {expected, index}, bad ->
    case TorrentClient.Disk.read_piece(download_dir, bento.info, index) do
      {:ok, data} ->
        if Torrent.verify_hash?(data, expected) do
          if rem(index, 500) == 0, do: Logger.info("... verified #{index}/#{length(hashes)}")
          bad
        else
          [index | bad]
        end

      {:error, reason} ->
        raise "piece #{index} unreadable: #{inspect(reason)}"
    end
  end)

case bad do
  [] -> Logger.info("disk verify ok=true (#{length(hashes)}/#{length(hashes)} pieces)")
  failed -> raise "disk verify failed for pieces: #{inspect(Enum.sort(failed))}"
end
