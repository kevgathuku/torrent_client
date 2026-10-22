# kog.13 handoff — session give-up must keep published progress

**Ticket:** `torrent_client-kog.13` (P1). **Acceptance:** repeated subtree
crash then give-up reports all pieces verified before the crash.

## The problem in one paragraph

A coordinator crash loses two things: in-flight blocks (never verified —
accepted loss, see kog.33) and, worse, *already-verified* pieces. The
coordinator restarts `:transient` under `TorrentSupervisor` (3 restarts /
60s) with the **same start opts it was born with**, including the
`verified` list from subtree start. The next `save_resume/1` then
**overwrites** `.resume` with that stale-or-narrower set, silently
discarding pieces the crashed incarnation had verified and published.
Separately, every give-up report is `{reason, info_hash}` — no verified
count — so the session's exhausted record cannot show, and `status`
cannot report, the progress that survived.

## What is already true (do not rebuild)

- **Write-before-report:** `complete_piece/1` calls `save_resume/1`
  (`lib/torrent_client/coordinator.ex` ~559) *before* the
  `{:piece_complete, index}` report is consumed — a verified piece is on
  disk before anyone hears about it. Staged temp-file + rename; failures
  only log.
- **Identity-checked load:** `load_verified/4`
  (`lib/torrent_client/session.ex` ~355) drops the resume file unless
  info-hash, total, *and* piece length all match. Hostile/corrupt resume
  bytes are already handled.
- **Live proof:** a real 250 MB download killed mid-way kept 129/479
  verified in `.resume`, resumed from 130 on re-add, and ran to 479/479.
  Clean-stop progress is settled; this ticket is crash-then-give-up only.
- **Telemetry exists now** (kog.30): per-piece complete/fail events with
  duration and bytes. Useful as test instrumentation (count events
  instead of sniffing logs), not as the persistence mechanism.

## The gaps, precisely

1. **Stale-opts restart clobbers `.resume`.** `init_state/1` takes
   `verified:` from opts (written once at `start_torrent`). After a
   crash-restart the in-memory set is missing every piece verified
   since start; the next save persists that regression. Repro: verify
   piece 0, kill the coordinator, verify piece 1, read `.resume` —
   piece 0 is gone.
2. **Give-up reports carry no progress.** `give_up/2` (~303) and the
   init-time exhausted arm (~152) and the stall-budget arm in
   `handle_stall/1` all report bare `{reason, info_hash}`. The session's
   exhausted entry (`status` shows only id/path/base_dir/status) cannot
   report "x/y verified", which is what the acceptance literally asks
   for.
3. **`terminate/2` publishes nothing.** Crash-path cleanup reaps orphans
   but the dying coordinator's `DownloadState` dies with it. Anything
   not yet saved to disk is gone (in-flight blocks — kog.33's problem,
   explicitly out of scope here).

## Suggested slices (smallest first)

- **Slice A — init merges disk state.** On `init`, read the resume file
  through the disk seam (`base_dir` + `Disk.decode_resume/1`, same
  identity check as `load_verified/4`) and union it with opts-provided
  verified indices. Crash-restart then resumes from *published*
  progress, and no save can regress the file. Watch out: init currently
  never touches disk — keep the read best-effort (missing/corrupt file
  = opts list, same as today).
- **Slice B — report verified on give-up.** Include the verified count
  (or list) in the give-up report and surface it in the session entry /
  `status`. This is the acceptance criterion made visible. Keep the
  report shape backward-compatible for existing `handle_info` clauses
  (extra map, not a bare-tuple change — the coordinator already changed
  the piece_complete shape once for reporter identity; don't repeat
  that churn).
- **Explicitly not this ticket:** in-flight block survival (kog.33),
  per-source verified accounting (kog.35 may reshape this),
  re-verification on load (trust + identity check stands).

## Test strategy

- **Red test for slice A:** 2-piece torrent, verify piece 0 (real
  seed or webseed mock), `Process.exit(coordinator_pid, :kill)`,
  verify piece 1, then read `.resume` off disk (or decode it) and
  assert piece 0 is still listed. Fails today (piece 0 dropped).
  Count fetches via the mock/seed to prove no refetch of piece 0
  after restart.
- **Red test for slice B:** force give-up after partial verification
  (e.g. dead swarm + webseed stubbed to fail after serving N pieces,
  or `max_peer_failures: 1` against refuse-loop) and assert the
  exhausted report/entry carries the verified count.
- **Telemetry as instrumentation:** attach handlers in these tests and
  assert `fetch_complete`/`piece_complete` counts instead of grepping
  logs — that is what kog.30 is for.

## Pitfalls (earned the hard way on kog.8–11, 30)

- **Supervisor intensity:** TorrentSupervisor allows 3 restarts / 60s.
  Crash-loop tests must stay under it or the *supervisor* dies and the
  test fails for the wrong reason. Kill once, assert, stop.
- **Abnormal exits need `trap_exit`** in the test, plus monitor refs
  for DOWN reasons (see webseed_worker_test setup).
- **No real network in unit tests:** loopback seeds + Mox doubles only
  (see `test/test_helper.exs` pattern). Timeouts: `recv_timeout: 2000`,
  never `assert_receive` without an explicit window.
- **Clocks:** `ManualClock` (see coordinator_test) for exact durations;
  the real clock for supervisor-timing tests (a frozen clock hangs
  time-based tests instead of failing).
- **Orphan semantics are load-bearing:** supervisor-restarted workers
  are reaped, their completions still count, their failures don't
  double-report. Any change to DOWN handling must re-run the orphan
  tests (`abnormal stop reaps live workers`, resume-seed tests).
- **Startup race:** `init` cannot stop `:normal` under a supervisor —
  terminal states from init must defer to the first message
  (`:finish_seeded` pattern), or the subtree reports failed-to-start.

## Related tickets (do not merge)

- kog.33 (sub-piece journal) owns in-flight survival; this ticket owns
  verified-set survival. The seam between them is `save_resume/1`.
- kog.35 (unified source abstraction) may move *where* verified lives;
  keep slice A/B storage-agnostic (read-modify via the Disk seam, not
  coordinator internals).
- kog.31 (adaptive timeouts) consumes the telemetry, not the resume
  file — no interaction, just shared vocabulary (`duration_ms`).
