# Changelog

All notable product changes are documented here. (Agent-workflow changes live
in `.agents/skills/` and are not tracked here.)

## [Unreleased]

### Added

- OTP Application with Registry plus session supervisor; per-identity addressing ends the named-singleton trap.
- Network, disk, and clock effect seams (behaviours + Mox doubles); workers take impls via start opts.
- BEP-3 peer wire codec: per-message structs, length-prefixed encode/decode with error envelopes, 16 KiB cap, IPv4/IPv6 compact parsing.
- Pure peer posture state with choke/interest transitions and a bitfield-to-index-set seam.
- Trust-boundary validators: tracker announce tiers, block-size bounds, path confinement, byte-identical re-encode fidelity per fixture.
- UDP tracker announces (BEP-15 codec, transport seam, supervised interval re-announcer with tier failover and exponential backoff); dictionary-model HTTP peers.
- Supervised peer worker: unnamed one-piece GenServer (handshake, bitfield, interest, choked-until-unchoked 16 KiB block requests, hash verify, disk write) under a bounded-intensity one-for-one supervisor; replaces the named singleton client.
- Block pipeline: up to 5 outstanding 16 KiB block requests per peer, per-piece deadline that publishes missing blocks for requeue and restarts within supervisor intensity; choke drops in-flight, unchoke re-requests.
- Bounded whole-announce fan-out: all trackers queried concurrently with peers merged as answers land (deduped, minimum interval kept); resolves within the timeout even when trackers black-hole.
- HTTP announces carry event/key parameters, honor tracker re-announce intervals, and fail closed on malformed bodies — at parity with the UDP path.
- Per-torrent coordinator: pure DownloadState plans rarest-first piece allocation, in-flight tracking, and endgame over worker reports (availability, block progress, completion); one supervised subtree per torrent with a stall watchdog (restarts stuck workers, gives up past the budget) and completion reporting; endgame duplicates race and the loser sends Cancel on first completion.
- Debug-level logging with a level-tagged file log (`log/torrent_client.log`, configurable) for post-mortems: lifecycle transitions at info, announce/resume detail at debug, fallbacks at warning, failures at error.
- Multi-torrent session plus CLI: `mix torrent download` runs the whole pipeline (parse, layout, announce, download with resume) and many torrents run concurrently; `mix torrent` also offers parse, status, pause, resume, forget (drop from the session, keep files), and remove (prompt-first data deletion with completeness-aware defaults, `--yes`, `--dry-run`). Restarts resume from per-torrent `.resume` files without re-downloading verified pieces; addressing is exact id, unique prefix, or torrent path; the session picks its listen port at startup (explicit, config file, or free OS pick with occupied-port fallback).

### Fixed

- Piece-hash slicing aligned to 20-byte boundaries past the first piece (every later piece verified against the wrong hash, so multi-piece downloads stalled on endless mismatches).
- HTTP tracker URLs percent-encode binary fields byte-wise (was space-as-`+`, corrupting info-hashes containing `0x20`).

- `info_hash` covers the full as-found info dict (was a `Map.take` subset, wrong swarm identity for torrents with extra keys); proven per fixture against raw info bytes.
- Integration-test timing flake (assert_receive window too tight under load).
- Tracker-supplied peers in loopback/unspecified/link-local/multicast ranges (IPv4 and IPv6, mapped forms judged by their embedded IPv4) are dropped before dialing; dictionary-model address text parses literally (dotted quad plus full, compressed, and mapped IPv6) and never triggers DNS resolution; dictionary-model ports outside 1..65535 reject the response, and compact peers with port 0 are dropped.
