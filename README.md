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

Start the downloader, providing a torrent file
```elixir
torrent_filename = "abcdefgh.torrent"
{:ok, pid} = Downloader.start_link(torrent_filename)
```

Stop the server
```elixir
{:ok, pid} = Downloader.stop(pid)
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/torrent_client](https://hexdocs.pm/torrent_client).
