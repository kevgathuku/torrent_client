# Daemon session owns N torrents across invocations

The goal is a Transmission-style daemon: one long-lived session process owns
every torrent, and CLI invocations are thin clients against it. On OTP this
is the home-turf shape — an `Application` supervision tree plus Erlang
distribution (`--remsh`, `:rpc`) covers inspection and control before any
custom RPC surface exists.

## Transmission mapping

- `tr_sessionInit(config_dir, settings)` creates one session bound to a
  config dir, starting bandwidth, DHT/PEX/uTP, port-forwarding, blocklist,
  and the announcer.
- `tr_sessionLoadTorrents` reloads every torrent plus resume state at
  startup. Adding a torrent works at any time against the running session.
- Thin clients (remote, GUI, web UI) all talk to the already-running
  session; torrents are independent entries with per-torrent state machines
  under global queue, scheduler, and bandwidth. One torrent failing never
  restarts its siblings.

## Decision

- The **session is a process tree, not a value**. The current single
  `Downloader` GenServer (born from a filename, dead at completion) is the
  stepping stone, not the end state.
- The daemon owns the config dir, loads all torrents plus resume state at
  start, accepts add/remove while running, persists per-torrent state
  periodically and on SIGTERM, and shuts down via a session-close
  equivalent.
- Hierarchy: session supervisor → one download-subtree per torrent
  (coordinator, peer supervisor, re-announcer, watchdog). Rest-for-one stays
  scoped per download subtree.
- One peer port, one peer id, one bandwidth/queue instance per daemon,
  shared across torrents — two concurrent runs must never double-bind them.

## Considered Options

- **Blocking single-shot entry as the end state**: rejected — every run
  would re-announce, re-bind the peer port, and orphan yesterday's
  torrents.
- **Perfect the single-shot flow first, convert later**: rejected as the
  default — queue and limit logic built on a throwaway lifetime needs
  rework at daemon time. If scheduling forces it, record the rework debt
  explicitly.
- **Persist supervisor counters for daemon recovery**: rejected — recovery
  goes through the download-record persistence seam, not supervisor
  internals.
