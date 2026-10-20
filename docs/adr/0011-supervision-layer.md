# Crash-only supervision on the real OTP tree

The crash-only principle from the constitution maps onto OTP supervisors
instead of hand-rolled machinery: a peer supervisor (`one_for_one`, owns
peer workers and the per-connection restart budget) under a per-torrent
download supervisor (`rest_for_one`, owns the coordinator plus siblings —
re-announcer, watchdog), all under a session supervisor with one subtree
per torrent. Restart intensity (`max_restarts`/`max_seconds`) replaces
budget code; intensity and watchdog deadlines are picked together per the
`restart-budget-math` memory. Workers never retry; crash detection is the
behaviour-envelope boundary (clean `{:error, _}` returns vs crashes, budgeted
identically, logged differently). Randomness stays a primitive injected
dependency consumed by a pure backoff helper shared by all supervisor slices.
SIGTERM triggers a clean shutdown: peer connections close, in-progress state
persists, then the node stops.

## Considered Options

- **Single supervisor at the download level**: rejected — a flaky peer
  should not restart the whole coordinator; grain differs per tier.
- **Per-address restart budget keyed on identity**: rejected — conflates
  identity with location; per-connection budget treats each handshake
  attempt independently.
- **Worker-level retries**: rejected — retry policy belongs to supervisors;
  workers crash and report.
- **Shaped randomness callbacks**: rejected — couples the seam to a
  time-domain concept with a pure home in the backoff helper. Seams stay
  primitive.
- **Merged completion signal without worker identity**: rejected — the
  restart decision needs to know which peer just exited; monitor by
  reference and map back to the address.
- **Crashes exempt from the per-connection budget**: rejected — a peer
  crashing N times still indicates a dead end; crashes and clean exits
  share budget treatment, distinguished only by log level.

## Consequences

- Per-connection budget lives in the peer supervisor (bounds churn on one
  address); per-subtree intensity lives in the download supervisor (bounds
  churn on the whole coordinator) — charged on coordinator crashes and
  exhaustion transitions, not on every peer restart.
- The crash path releases what the child held (connections closed in
  `terminate`, in-flight pieces requeued) before the supervisor restarts —
  see `crash-path-cleanup` and `requeue-inflight-on-restart`.
- Give-up reports the record the crashed attempt published, threaded up
  every tier — see `progress-up-the-hierarchy`.
