# Issue tracker: Beads

Issues live in a local Dolt database (`.beads/dolt/`), operated via the `bd` CLI.
Run `bd prime` for full workflow context and command reference.

## Conventions

- `bd ready` — find available work
- `bd show <id>` — view issue details
- `bd update <id> --claim` — claim work atomically before starting
- `bd close <id>` — complete work
- `bd remember` — persistent project memory; no ad hoc memory files
- All task tracking goes through `bd` — no markdown TODO lists

## When a skill says "publish to the issue tracker"

File it with `bd` (see `bd prime` for the current create flags).
Cross-machine sync is `bd dolt push` / `bd dolt pull` (stored under
`refs/dolt/data` on the git remote). `.beads/issues.jsonl` is a passive
export, never the source of truth.

## When a skill says "fetch the relevant ticket"

Run `bd show <id>`. If the reference is ambiguous, ask.
