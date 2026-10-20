# Orchestration behind behaviour seams over GenServers

All effects cross injectable behaviours (network, disk, time, randomness);
peer concurrency runs on supervised GenServers with explicit ownership, and
every runtime fact lives in the download state — no ambient config, no global
names for per-torrent processes. Verified pieces stream straight to the file
layout via piece-to-file offsets instead of buffering in memory, and the
lifecycle is the explicit states `:idle → :starting → :downloading →
:completed | :paused | :failed`.

## Considered Options

- **One process per peer without supervision**: rejected — orphan processes
  on crash, no restart story.
- **Direct `:gen_tcp`/`File` calls in coordination code**: rejected — they
  violate explicit-effects and no-hidden-state principles.
- **Buffer-all-then-write**: rejected — memory-intensive for large torrents.
