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
- Purity tripwire test over the domain files; mutation-rejection properties for fail-closed decoding.
- 80% total coverage gate and `mix dialyzer` in the quality gates.

### Fixed

- `info_hash` covers the full as-found info dict (was a `Map.take` subset, wrong swarm identity for torrents with extra keys); proven per fixture against raw info bytes.
- Integration-test timing flake (assert_receive window too tight under load).
