# Changelog

All notable changes to this project are documented here. Agent-workflow
changes (skills) are listed alongside product changes; process entries affect
how work is done, not what ships.

## [Unreleased]

### Added — agent workflow

- Implement skill runs per-issue branches (`<type>/<ticket>-<slug>`), never `main`.
- Implement pre-checks: graft code-path mapping, `bd prime` + beads memory recall, BEP-first for protocol behaviour.
- Done gates: `mix test`, `mix credo --strict`, `mix dialyzer`, 80% total coverage, both-directions coverage for new public functions, mutation-based generative specs for fail-closed branches, residues recorded at the test site.
- Self-review via the `code-review` skill (fixed point `main`) before opening a PR, including a clojure.spec judgement call.
- Docs consistency pass before PRs (docs search, CHANGELOG entry for user-visible behavior).
- PR skill adopts the `Implements <bead-id>` / What changed / Verification / Merge danger format.
- `mix format` check required before every commit.
