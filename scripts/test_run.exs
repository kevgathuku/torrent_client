# Manual smoke helper, kept out of application code.
# Usage: mix run scripts/test_run.exs [torrent_file] [download_dir]
#
# Exercises the real pipeline: parse -> info-hash -> disk layout ->
# tracker peer fetch -> supervised worker download -> resume codec round-trip.
# The peer fetch hits the network; the worker download runs against a
# loopback fake seed, so it needs nothing beyond this machine. Exits 0 even
# when trackers are unreachable (prints what happened instead of crashing).
require Logger

args = System.argv()
torrent_filename = Enum.at(args, 0, "test/_data/debian-12.1.0-amd64-netinst.iso.torrent")
download_dir = Enum.at(args, 1, Path.join(System.tmp_dir!(), "smoke"))

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

if first = List.first(peers),
  do: Logger.info("first peer=#{inspect(Map.take(first, [:ip_tuple, :port]))}")

# 4. Supervised peer worker: download one synthetic piece from a loopback
# fake seed through the real worker, disk, and supervisor.
fake_info = %{:"piece length" => 16_384, name: "smoke.bin", length: 16_384}
fake_data = :crypto.strong_rand_bytes(16_384)
fake_hash = :crypto.hash(:sha, fake_data)
fake_dir = Path.join(download_dir, "smoke-worker")
File.mkdir_p!(fake_dir)
:ok = TorrentClient.Disk.init_layout(fake_dir, fake_info)

{:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
{:ok, fake_port} = :inet.port(listen)

spawn(fn ->
  {:ok, sock} = :gen_tcp.accept(listen, 5_000)
  {:ok, hs} = :gen_tcp.recv(sock, 68, 5_000)
  {:ok, %Handshake{info_hash: hash}} = Handshake.deserialize(hs)

  :ok =
    :gen_tcp.send(sock, Handshake.init(hash, String.duplicate("S", 20)) |> Handshake.serialize())

  {:ok, bits} = PeerMessage.encode(%PeerMessage.Bitfield{bits: <<0b10000000>>})
  :ok = :gen_tcp.send(sock, bits)
  # Interest + unchoke from the worker: two fixed 5-byte messages.
  {:ok, _} = :gen_tcp.recv(sock, 10, 5_000)
  {:ok, unchoke} = PeerMessage.encode(%PeerMessage.Unchoke{})
  :ok = :gen_tcp.send(sock, unchoke)
  # One 16 KiB block request, then the piece itself.
  {:ok, <<13::32-big, 6, 0::32-big, 0::32-big, 16_384::32-big>>} = :gen_tcp.recv(sock, 17, 5_000)
  {:ok, piece} = PeerMessage.encode(%PeerMessage.Piece{index: 0, begin: 0, block: fake_data})
  :ok = :gen_tcp.send(sock, piece)
end)

{:ok, sup} = TorrentClient.PeerSupervisor.start_link()

{:ok, worker} =
  TorrentClient.PeerSupervisor.start_peer(sup,
    peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: fake_port},
    info_hash: :crypto.strong_rand_bytes(20),
    peer_id: Utils.generate_peer_id(),
    info: fake_info,
    piece_index: 0,
    piece_hash: fake_hash,
    base_dir: fake_dir
  )

ref = Process.monitor(worker)

receive do
  {:DOWN, ^ref, :process, ^worker, :normal} -> :ok
after
  10_000 -> raise "worker did not finish"
end

{:ok, ^fake_data} = TorrentClient.Disk.read_piece(fake_dir, fake_info, 0)
Logger.info("worker download ok=true")

# 5. Pause/resume codec round-trip through the real disk seam.
resume = %{info_hash: Utils.sha_sum("smoke"), verified: MapSet.new(), total: 1, piece_length: 1}
{:ok, encoded} = TorrentClient.Disk.encode_resume(resume)
resume_path = Path.join(download_dir, "resume.bin")
:ok = TorrentClient.Disk.write(resume_path, encoded)
{:ok, stored} = TorrentClient.Disk.read(resume_path)
{:ok, decoded} = TorrentClient.Disk.decode_resume(stored)
Logger.info("resume round-trip ok=#{decoded == %{resume | verified: []}}")

Downloader.stop(pid)
