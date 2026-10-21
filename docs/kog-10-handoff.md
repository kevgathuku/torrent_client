# Handoff: implementing torrent_client-kog.10 (Session, persistence, config, CLI)

Bead: `torrent_client-kog.10` (P1, depends on kog.9 ✓ merged as #18, blocks kog.11/13/14/25).
Acceptance: **two torrents run concurrently; restart resumes without re-verified loss.**
Prior context: `bd memories` (`kog-9-*`, `progress-up-the-hierarchy`, `restart-budget-math`,
`empty-swarm-not-final`, `crash-path-cleanup`, `requeue-in-flight-on-restart`), plus the
kog.13 comment holding the state-storage tradeoff analysis, and
`docs/overview.html` (uncommitted architecture explainer — keep or drop, do not merge silently).

## What exists today (kog.9 and before)

- `TorrentClient.Application` starts a unique `Registry` and a `SessionSupervisor`
  (DynamicSupervisor). **There is no session GenServer yet** — that is this ticket.
- `TorrentClient.TorrentSupervisor` (`lib/torrent_client/torrent_supervisor.ex`): one supervised
  subtree per torrent, `:one_for_one`, intensity 3 restarts / 60 s. Children: unnamed
  `PeerSupervisor` (transient workers, 3 restarts / 10 s) + `Coordinator` (`:transient` —
  `:normal` stops never restart). Both registered as `{info_hash, :peer_sup | :coordinator}`.
- `TorrentClient.Coordinator` owns all per-torrent state: rarest-first assignment
  (`DownloadState`, pure), in-flight tracking, endgame duplication with wire Cancel,
  stall watchdog (restart workers, give up past the budget), poison-peer skip.
- `TorrentClient.Announcer` exists but is **standalone** — no supervisor owns it yet.
  It does interval re-announces (tier walk) and `announce_all/3` bounded fan-out
  (deduped merge, min interval). Session wiring belongs here.
- `TorrentClient.Disk.encode_resume/decode_resume` exists and is tested, but has
  **zero production callers**. Resume map: `%{info_hash: raw_bytes, verified: [indices],
  total: n, piece_length: n}`, term_to_binary with a version tag.
- `Downloader` (`lib/downloader.ex`): legacy named-singleton entry point. Only its
  `parse_torrent_file/1` is still load-bearing (fixture parsing in tests + smoke script).
  The GenServer half (peer fetch, worker startup) is dead — session replaces it.
  Do not extend it; shrink or delete it here if convenient (move `parse_torrent_file`
  somewhere neutral first — it has ~10 call sites, all tests).
- Effect seams (behaviours + Mox doubles, opts-injected): Network, Disk, Clock,
  Socket, UDP, Requests. Keep the pattern for anything new with side effects.

## The coordinator contract (what the session drives)

Start per torrent via `TorrentSupervisor.start_link/1`. Required opts: `:info_hash`,
`:info` (torrent info map), `:piece_hashes` (list of raw 20-byte SHA1s),
`:base_dir`, `:peer_sup` (injected by the supervisor — callers never pass it).
Optional: `:peers` (static list; the session will supply announce results here),
`:peer_id`, `:report_to`, `:max_peers` (default 4), `:max_inflight` (5),
`:watchdog_timeout` ms (60_000), `:max_stalls` (3), `:max_peer_failures` (3),
`:recv_timeout`/`:piece_timeout` ms, effect seams, `:name`.

Terminal reports to `report_to` (all followed by `:normal` stop, never a restart —
retry policy is yours):
- `{:torrent_complete, info_hash}` — everything verified.
- `{:swarm_exhausted, info_hash}` — no workers and nothing assignable.
  **Do not treat this as final while trackers can refill the swarm**
  (`empty-swarm-not-final`): re-announce before giving up for real.
- `{:download_stalled, info_hash}` — no block progress within budget × stalls.
- `{:peer_skipped, {ip, port}}` — informational, peer past the failure budget.

## Conventions to lock on day one

- **info_hash is two types: pick the boundary.** `Torrent.info_hash/1` returns a hex
  string (tracker URLs, logging, Registry keys). The wire handshake and
  `piece_hashes` are **raw 20 bytes** (all tests use raw; a hex string silently
  makes 88-byte handshakes). Recommendation: raw bytes inside coordinator/worker,
  hex only at the tracker-URL/logging boundary. Document whichever you choose —
  this bit us once already (smoke script).
- **peer_id**: `Utils.generate_peer_id/1` mints a fresh random id per call, and the
  coordinator calls it per start. Session-stable peer id is kog.18 — until then,
  generate once per session/torrent and pass it down; do not mint per restart or
  trackers see flapping identities.
- **peer identity for addressing**: `{ip_tuple, port}` tuples (Registry keys are
  `{info_hash, :peer_sup | :coordinator}`; add `{info_hash, :session}` or similar —
  keep the scheme).
- **Timeouts are milliseconds integers**; `max_peers` is validated positive in
  `Coordinator.init` (fail fast `{:error, {:invalid_opts, _}}`) after a silent-forever
  stall was found and fixed. Validate user-supplied config at parse time too —
  config arrives as strings and the coordinator will not coerce it for you.
- **Listen port**: `Utils.get_port/0` exists and is tested — call it at runtime in
  `init`, never in a module attribute (`@init_state` evaluates once at compile time).
  Starting two daemons (or one on an occupied port) must never silently collide — cover it.

## Supervision shape decision

kog.9 ships `:one_for_one` (coordinator restarts must not kill in-flight workers;
the new incarnation reaps orphans on init). ADR-0011 sketches `:rest_for_one` with
re-announcer + watchdog as siblings — that shape makes sense once the announcer
moves under the per-torrent supervisor. Either reaffirm one_for_one with the
announcer as a third independent child, or move to rest_for_one with ordering
arguments; keep intensity budgets paired with watchdog deadlines
(`restart-budget-math`: L restarts per window W need stall deadlines ≤ W/(L+1)).

## Persistence: what goes where (kog.10 vs kog.13)

- kog.10 owns: where resume state lives (file location, naming), loading it at
  session/torrent start, and handing verified sets to the coordinator at startup
  (Coordinator currently always starts empty — add the seed path).
- kog.13 owns: crash-path reporting (give-up must keep *published* progress).
- Hard rules already established: **data before resume mark** (never record a piece
  the bytes don't back), temp-file + rename (no atomic guarantee from `File.write`),
  and distrust-on-load at least for torrent identity (the codec already carries
  info_hash/total/piece_length — check them before trusting `verified`).

## CLI surface (per bead notes)

Thin commands: parse, download, pause, resume, status, stop. Addressing: exact id
first, torrent-path fallback second (from closed clj bead 0c9.21). Control surface:
on OTP, `remsh`/rpc covers inspection first — record whether a custom RPC is still
needed (clj bead 0c9.14). Pausing a download = stop its subtree; resume = start it
back with the persisted verified set.

## Test entry points

- `test/coordinator_test.exs`: loopback-seed integration pattern (greet + serve +
  accept loops). Clock is injectable — `ManualClock` pattern in-file freezes time
  for deterministic watchdog tests.
- `test/download_state_test.exs` + `test/peer_compact_property_test.exs`: pure +
  generative seams; extend, don't duplicate.
- `scripts/test_run.exs`: rewritten smoke script (coordinator download, loopback UDP,
  fan-out stubs, validation asserts, watchdog, resume round-trip). **Unverified as
  of this writing** — needs one full green run (a Downloader sync-HTTP hang on some
  fixtures forced a sys-timeout-tolerant poll loop; confirm it).
- Coverage bar holds: total ≥ 80%, every new/changed line covered; documented
  residues live at the test site, not in PR bodies.

## Known traps (learned the hard way this round)

- `finish/1` must NOT terminate duplicate workers — the cancel loses the race and
  the Cancel never reaches the wire. Give-up paths have no such constraint.
- The peer supervisor restarts crashed workers with the same piece; the coordinator
  reaps orphans on DOWN/init/terminate. Never name workers (pids only).
- Availability reports are monotonic per peer; `missing` entries clear when covered.
- `max_peers` unvalidated once caused a silent-forever stall; now fails fast.
- Another agent edited this tree mid-flight twice (a records-store injection into the
  coordinator, since reverted; a one-line announcer cleanup). **Start with
  `git status` + a gates run**, and keep beads as the coordination point.

## Suggested slice order

1. Session GenServer + Registry keys + per-torrent startup (two torrents, distinct dirs).
2. Config file + listen port + no-collision test.
3. Announcer under the per-torrent supervisor; re-announce-before-give-up.
4. Resume load at startup (save can follow in kog.13; loading unblocks the AC's second half).
5. CLI thin wrappers + addressing.
6. Retire the Downloader GenServer half; keep or move `parse_torrent_file/1`.
