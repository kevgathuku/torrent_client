# TorrentClient

A simple Elixir torrent client, based on [Building a BitTorrent client from the ground up in Go](https://blog.jse.li/posts/torrent/)

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `torrent_client` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:torrent_client, "~> 0.1.0"}
  ]
end
```

# Usage

End-to-end pipeline (`iex -S mix`). Steps that have no machinery yet are marked `#pending`.

1. Parse the torrent file
```elixir
{:ok, bento, info} = Downloader.parse_torrent_file("path/to/file.torrent")
info_hash = Torrent.info_hash(info)
```

2. Prepare the download layout
```elixir
:ok = TorrentClient.Disk.init_layout("/downloads", bento.info)
```
Creates one file per torrent entry at its declared size. Hostile paths (`..`, absolute) are rejected before anything is created.

3. Ask trackers for peers
```elixir
{:ok, pid} = Downloader.start_link("path/to/file.torrent")
:sys.get_state(pid).peers
```
Peers are fetched on init over HTTP; UDP and multi-tier announces live in `TorrentClient.Announcer`.

Stop the server with `Downloader.stop(pid)`.

4. #pending Download pieces from peers (supervised peer worker — kog.8)

5. #pending Coordinate verified writes to disk with watchdog re-requests (per-torrent coordinator — kog.9)

6. Pause/resume state (codec done, coordinator wiring #pending)
```elixir
# Pause: encode verified progress and store the bytes
{:ok, encoded} = TorrentClient.Disk.encode_resume(%{
  info_hash: Utils.sha_sum("seed-bytes"),
  verified: MapSet.new([0, 1]),
  total: 10,
  piece_length: 4
})
:ok = TorrentClient.Disk.write("/downloads/resume.bin", encoded)

# Resume: load the bytes back and decode
{:ok, bytes} = TorrentClient.Disk.read("/downloads/resume.bin")
{:ok, %{info_hash: hash, verified: indices}} = TorrentClient.Disk.decode_resume(bytes)
# #pending re-verify `indices` against piece hashes and fetch the rest (kog.9)
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/torrent_client](https://hexdocs.pm/torrent_client).
