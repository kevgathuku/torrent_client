defmodule TorrentClient.Telemetry do
  @moduledoc """
  Telemetry event contract for the download path. Callers emit through
  `emit/3`; handlers attach with `:telemetry.attach_many/4` on any
  subset. With nothing attached, `emit/3` is a map lookup and returns
  `:ok` — measurement costs nothing by default.

  All durations are integer milliseconds from the coordinator's clock
  seam (frozen in tests, monotonic in production). `info_hash` is the
  raw 20-byte binary the coordinator is keyed on.

  Events (all under `[:torrent_client]`):

  - `[:torrent_client, :peer, :piece_complete]` — a peer worker's bytes
    verified. Measurements: `%{duration_ms, bytes}` (`bytes` is the
    verified piece size). Metadata: `%{info_hash, index, peer}` (`peer`
    is the `{ip, port}` key).
  - `[:torrent_client, :peer, :piece_failed]` — a peer assignment
    requeued. Measurements: `%{duration_ms}` (assignment to the DOWN
    that requeued it). Metadata: `%{info_hash, index, peer, reason}`.
  - `[:torrent_client, :webseed, :fetch_complete]` — a webseed worker's
    bytes verified. Measurements: `%{duration_ms, bytes}`. Metadata:
    `%{info_hash, index}`.
  - `[:torrent_client, :webseed, :fetch_failed]` — a webseed assignment
    requeued. Measurements: `%{duration_ms}`. Metadata:
    `%{info_hash, index, reason}`.
  - `[:torrent_client, :coordinator, :stall]` — the watchdog restarted
    stuck workers. Measurements: `%{stall_count}` (the new count).
    Metadata: `%{info_hash}`.
  - `[:torrent_client, :coordinator, :give_up]` — terminal stop with a
    report. Measurements: `%{}`. Metadata: `%{info_hash, reason}`
    (`:swarm_exhausted` or `:download_stalled`).
  """

  @doc "Emit a telemetry event. No-op when nothing is attached."
  def emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
