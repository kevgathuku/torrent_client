# TorrentClient

[![Coverage Status](https://coveralls.io/repos/github/kevgathuku/torrent_client/badge.svg?branch=main)](https://coveralls.io/github/kevgathuku/torrent_client?branch=main)

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

## Downloading (CLI)

One command runs the whole pipeline — parse, layout, tracker announce,
download with resume:

```bash
mix torrent download path/to/file.torrent --dir ~/downloads
```

The session announces to every tracker, downloads with rarest-first
assignment plus watchdog retries, publishes verified pieces to
`<dir>/.resume` as they complete, and prints `complete <id>` when done.
Restarting the same command (or the node) resumes from `.resume` —
already-verified pieces are never re-downloaded. Many torrents run
concurrently, each in its own supervised subtree and directory.

## All commands

```bash
mix torrent parse path/to/file.torrent            # info-hash, piece count, total bytes
mix torrent download path/to/file.torrent [--dir DIR] [--timeout MS]
mix torrent status                                # every torrent: id, status, path, dir
mix torrent status <id-or-path>                   # filter to one torrent
mix torrent pause <id-or-path>                    # stop its workers, keep state
mix torrent resume <id-or-path>                   # restart with the saved resume
mix torrent forget <id-or-path>                   # drop from the session, keep files
mix torrent remove <id-or-path> [--yes] [--dry-run]
```

`remove` deletes the layout files plus `.resume` (parent directories,
possibly shared, survive). It prompts first — defaulting to keep a
complete torrent's files and delete an incomplete one's; `--yes` skips
the prompt, `--dry-run` only lists what would go.

Addressing is exact hex id first, unique id prefix second, torrent
path third:

```bash
mix torrent pause 9F2C...        # full id
mix torrent pause 9F2C          # unambiguous prefix
mix torrent pause file.torrent  # path fallback
```

Cross-node control needs no custom protocol: connect with remsh and
call `TorrentClient.Session` (`Node.connect/1` + `:rpc.call/4`).

## Programmatic

```elixir
{:ok, id} = TorrentClient.Session.add_torrent("path/to/file.torrent", base_dir: "~/downloads")
TorrentClient.Session.status()          # [%{id: _, path: _, base_dir: _, status: _}]
TorrentClient.Session.pause(id)
TorrentClient.Session.resume(id)
TorrentClient.Session.forget(id)        # drop entry, keep data
{:ok, ^id, files} = TorrentClient.Session.remove(id, dry_run: true)
```

Statuses: `:downloading | :paused | :complete | :stalled | :exhausted`.

## Configuration

The session picks its listen port once at startup: an explicit `:port`,
else the port from `:config_path`, else a free OS-assigned port. A
configured port that is already taken falls back to a free one rather
than colliding. The config file is `key = value`, one per line
(`#` comments, unknown keys ignored):

```
# client.conf
port = 6881
```

```elixir
# releases: config/config.exs
config :torrent_client, session: [port: 6881, config_path: "client.conf"]
```

## Logging

Levels follow the event, not the module: `debug` for routine detail
(port pick, per-tracker announce outcomes, resume hits), `info` for
lifecycle transitions (added, paused, resumed, forgotten, removed,
complete), `warning` for degraded-but-continuing (occupied-port
fallback, distrusted resume bytes, failed resume save), `error` for
failed operations.

A debug-and-up file log lands at `log/torrent_client.log` (level-tagged
lines for post-mortems); the console keeps its own level, controlled per
invocation with `mix torrent --log-level <debug|info|warning|error>`
(default `info`). Disable or relocate the file with app config:

```elixir
# config/config.exs
config :torrent_client, log_file: nil                  # disable
config :torrent_client, log_file: "/var/log/torrent.log"
```

## Internals (per-torrent machinery the session drives)

- Layout: `TorrentClient.Disk.init_layout(dir, bento.info)` creates one
  file per torrent entry at its declared size. Hostile paths (`..`,
  absolute) are rejected before anything is created.
- Peer worker: handshakes, sends interest plus unchoke, requests the
  piece in 16 KiB blocks (up to five in flight) while unchoked and under
  a per-piece deadline, verifies the SHA1, and writes through the disk
  seam — then exits `:normal` (which never restarts). Failures stop
  fail-closed and the supervisor restarts them bounded by intensity.
- Coordinator: rarest-first assignment, in-flight tracking, endgame
  duplication with wire Cancel, stall watchdog with a give-up budget,
  poison-peer skip, and one re-announce before giving up on an empty
  swarm.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/torrent_client](https://hexdocs.pm/torrent_client).
