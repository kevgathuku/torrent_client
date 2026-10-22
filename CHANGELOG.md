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
- Webseed (BEP-19) fallback: torrents carrying `url-list` fetch missing pieces over HTTP Range requests (dir-base plus name/path, or verbatim single-file URLs; unknown schemes skipped) with SHA1 verification through the existing piece path. The coordinator treats webseeds as a last resort — peers always win — so dead swarms still make progress and partially-seeded torrents fill their gaps; a torrent with webseed URLs no longer idles as exhausted when no peers answer.
- Peer wire encryption (MSE/PE): `PeerWorker` takes `:encryption` (`:plaintext` default, `:prefer_mse` with plaintext fallback on a fresh connection, `:require_mse` fail-closed), threaded from session/coordinator opts; RC4-only offer, stream positions continuous across negotiation into payload.
- Message Stream Encryption (MSE/PE) handshake codec (`TorrentClient.MSE`): DH key exchange over the 768-bit spec prime, req1/req2/req3 sync hashes, VC plus crypto negotiation, and the RC4 stream (hand-rolled — OTP's OpenSSL ships without RC4). Transport-free and opt-in; the plaintext BEP-3 path is unchanged.
- Telemetry events (`:telemetry`) on the download path: per-piece complete/fail with duration and bytes for peer and webseed fetches, watchdog stall and give-up reports. No-op without attached handlers; provides the numbers future adaptive timeouts will tune against.
- Multi-torrent session plus CLI: `mix torrent download` runs the whole pipeline (parse, layout, announce, download with resume) and many torrents run concurrently; `mix torrent` also offers parse, status, pause, resume, forget (drop from the session, keep files), and remove (prompt-first data deletion with completeness-aware defaults, `--yes`, `--dry-run`). Restarts resume from per-torrent `.resume` files without re-downloading verified pieces; addressing is exact id, unique prefix, or torrent path; the session picks its listen port at startup (explicit, config file, or free OS pick with occupied-port fallback).

### Fixed

- Crash-restarted downloads keep the pieces they already published: the coordinator reseeds its verified set from the torrent's `.resume` file instead of the stale start opts, and give-up reports carry verified/total so `Session.status/1` and `mix torrent status` show the progress that survived. In-flight block loss (kog.33) is unchanged.
- A torrent whose supervisor keeps dying no longer slips out of session control: the session monitors every subtree, restarts a crashed one from resume state, and marks it exhausted after 3 restarts — so pause/forget always stop the live subtree and a crash loop ends in a terminal entry instead of spinning silently.
- Tracker HTTP queries carry their own 5s inner timeout: one blackholed tracker fails fast instead of eating the whole announce window (the fan-out timeout stays the outer bound).
- Peer downloads adapt to the link: the block pipeline grows past 5 on fast links (cap 16, ~35% faster on 100ms-RTT loopback) and backs off instead of dying on jitter, receive timeouts derive from observed block latency, and silent peers fail fast on a 5s first-byte deadline so poison peers are skipped in ~20s instead of minutes.

- Piece-hash slicing aligned to 20-byte boundaries past the first piece (every later piece verified against the wrong hash, so multi-piece downloads stalled on endless mismatches).
- HTTP tracker URLs percent-encode binary fields byte-wise (was space-as-`+`, corrupting info-hashes containing `0x20`).

- `info_hash` covers the full as-found info dict (was a `Map.take` subset, wrong swarm identity for torrents with extra keys); proven per fixture against raw info bytes.
- Integration-test timing flake (assert_receive window too tight under load).
- Tracker-supplied peers in loopback/unspecified/link-local/multicast ranges (IPv4 and IPv6, mapped forms judged by their embedded IPv4) are dropped before dialing; dictionary-model address text parses literally (dotted quad plus full, compressed, and mapped IPv6) and never triggers DNS resolution; dictionary-model ports outside 1..65535 reject the response, and compact peers with port 0 are dropped.
