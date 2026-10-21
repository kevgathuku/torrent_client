# RPC interface evaluation (Transmission spec)

**Question:** should the daemon/control-plane split (issue #1 in the
improvement review) use an RPC interface shaped like
[Transmission's `rpc-spec.md`](https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md)
(JSON-RPC 2.0 over HTTP, `rpc_version_semver` 6.0.0 at time of writing)?

**Verdict:** adopt the *envelope and method-shape conventions*, implement a
*small subset* (8 methods), serve it with **zero new dependencies**
(`:inets` httpd + OTP `:json`, both verified present in this toolchain),
and skip full parity — most of Transmission's surface describes features
we don't have (seeding, queues, limits, per-peer stats).

## What the spec actually says (primary source)

- **Envelope:** JSON-RPC 2.0, params-by-name only (objects, never
  positional); results under `result`, errors as `{code, message, data?
  {error_string?, result?}}` (§2, §2.1). HTTP 200 for everything,
  204 for notifications (§2.2).
- **Transport:** HTTP POST to a reconfigurable path (default
  `:9091/transmission/rpc`); clients must allow reconfiguration (§2.2).
- **CSRF:** servers require `X-Transmission-Session-Id`; a wrong id
  gets HTTP 409 carrying the right id, and the client retries (§2.2.1).
- **Rebinding/auth:** `Host:` whitelist (localhost/IPs always allowed)
  is on by default (§2.2.2); HTTP Basic is optional (§2.2.3).
- **Addressing:** `ids` = int id | list of ids/hash strings |
  `"recently_active"`; **integer ids are unstable across restarts —
  use hashes** (§3.1).
- **Methods that matter to us:** `torrent_start/stop/verify/reannounce`,
  `torrent_set` (large mutator: limits, priorities, `files_wanted`,
  `sequential_download`, `tracker_list`, seed ratios), `torrent_get`
  (`fields` array, `objects`|`table` formats, ~80 fields),
  `torrent_add` (`filename` **or** base64 `metainfo`, `download_dir`,
  `paused`), `torrent_remove` (`delete_local_data`),
  `torrent_set_location`, `torrent_rename_path`; `session_get/set`
  (large param list: speed limits, queues, dirs, `dht_enabled`,
  `encryption`, ports…), `session_stats`, `blocklist_update`,
  `port_test`, `session_close`, queue moves, `free_space`,
  bandwidth groups (§3–§4).
- **Versioning:** `session_get` → `rpc_version_semver`; the 409 also
  carries `X-Transmission-Rpc-Version` so dual-protocol clients can
  pick a scheme with no extra round trip (§5).
- **Telling details:** `webseeds` is deprecated in favor of
  `webseeds_ex` (url + is_downloading + B/s); status is a 0–6 enum
  (stopped…seeding); `peers_from` breaks peers down by source
  (tracker/dht/pex/…); integer `id` exists only for display.

## Fit against our Session API today

| Transmission method | Our equivalent | Gap |
|---|---|---|
| `torrent_add` (metainfo) | `Session.add_torrent(path, opts)` | ours takes a path; add base64 `metainfo` variant |
| `torrent_start/stop` | `resume` / `pause` | rename only |
| `torrent_remove` + `delete_local_data` | `forget` / `remove --yes/--dry-run` | rename only |
| `torrent_get` (fields) | `Session.status()` (id/path/base_dir/status only) | needs verified-count, total, rate fields |
| `torrent_verify` | — | no re-verify path ( kog.13-adjacent) |
| `torrent_reannounce` | — | re-announce is internal-only |
| `torrent_set` (90%) | — | no limits/priorities/queues yet (kog.20/21) |
| `session_get/set/stats` | config file + `port` | no runtime session params, no counters |
| `session_close` | — | no daemon to close (this is the point) |

## Recommendation

**Adopt:** JSON-RPC 2.0 envelope (method/params/id, named params,
`result`/`error`), `ids`-as-hashes addressing, `fields`-based
`torrent_get`, `torrent_add` with `metainfo`, `session_close`,
semver reporting. These are good design regardless of Transmission:
self-describing, debuggable with curl, and third-party clients
(transmission-remote scripts, phone apps) could talk to us with
trivial shims for the subset we implement.

**Do not adopt (yet):** `torrent_set` beyond `peer_limit`-style
knobs we actually own; the ~80-field `torrent_get` (serve ~12:
`hash_string name status percent_done total_size rate_download
rate_upload peers_connected download_dir error error_string
added_date files file_stats`); `table` format; queue moves/groups/
scripts/units; Basic auth on day one.

**Transport: `:inets` httpd + `:json`, no new deps.**
Verified in this toolchain (Elixir 1.20/OTP 29): `:json.decode/1`
exists, `:httpd` is present. This upholds the minimal-runtime-deps
rule (a Bandit+Plug+Jason stack is three new runtime deps for a
loopback daemon that serves one client). Revisit if we ever need
websockets (progress push), TLS client certs, or pipelining
performance httpd can't give. Run loopback-only by default; the
CSRF 409 dance is only needed if we ever bind non-loopback or
serve browsers — structure the handler so the session-id check is
one wrapper, but leave it off while loopback-only (document why).

**IDs: skip integer ids entirely.** Our hex info-hash ids are
already stable across restarts — the property Transmission tells
clients to prefer. `recently_active` can come later with the
activity tracking it needs.

**Minimal slice (shipped order):**
1. `session_get` (`version`, `rpc_version_semver`, `download_dir`,
   `peer_port`) + `session_close` + 409/`X-Transmission-Rpc-Version`
   scaffolding — proves the envelope.
2. `torrent_add` (metainfo), `torrent_get` (12 fields),
   `torrent_start/stop/remove`, `torrent_reannounce`.
3. `torrent_verify`, `session_stats` (needs byte counters we don't
   keep — add them to the coordinator report path first).
4. `mix torrent` becomes a thin client over this (local HTTP),
   keeping every current verb working unchanged.

**Error mapping:** our tagged tuples map 1:1 —
`{:error, :not_found}` → `-32602`-style invalid-params… actually
prefer Transmission-style application codes with `error_string`
carrying `inspect(reason)` (fail-closed detail preserved, no atom
leak: atoms never cross the boundary, only strings/numbers).

## Open questions (for kog.12/28/20, not this evaluation)

- Seeding stats (`uploaded_ever`, `upload_ratio`, `seconds_seeding`)
  need coordinator counters that don't exist yet.
- `peers_from`-style source breakdown wants per-source peer
  provenance we don't track.
- `encryption`/`preferred_transports` params should stay absent
  until MSE/uTP exist, or clients will set flags we ignore.
