# Manual smoke helper, kept out of application code.
# Usage: mix run scripts/test_run.exs [torrent_file]
torrent_filename =
  List.first(System.argv(), "test/_data/debian-12.1.0-amd64-netinst.iso.torrent")

unless File.exists?(torrent_filename) do
  raise "torrent file not found: #{torrent_filename}"
end

# Start the server
{:ok, pid} = Downloader.start_link(torrent_filename)
# Fetch peers -> Should now be done automatically
# fetch_peers(pid)

# filter_connected_peers(server)

# TODO: Call this after some time
# OR have GenServer tell us when the filtering is complete
state = :sys.get_state(pid)
connected_peers = Enum.count(state.peers)
Logger.debug("Connected peers: #{connected_peers}")
