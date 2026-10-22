---
name: address-pr-review
description: "Address PR review findings: validate each thread against the code, fix confirmed ones with TDD, reply per thread, push the fixes. Use when the user says 'address the PR comments', 'review the PR comments', or names a PR with findings."
---

# Skill: address-pr-review

Work every finding on a pull request to done: validated, fixed with tests where confirmed, rebutted with proof where not, replied per thread, fixes pushed.

## 1. Fetch the threads

- Overview: `gh pr view <number> --comments` plus `gh pr view <number> --json reviews`.
- Inline threads with reply IDs: `gh api repos/<owner>/<repo>/pulls/<number>/comments` (keep each comment's `id`, `path`, `line` — replies need the thread id).
- Only work unresolved threads: check `isResolved` via the GraphQL `reviewThreads` field and skip resolved ones entirely.

Done when every unresolved thread is listed with its location.

## 2. Validate each finding

For every finding, open the cited file:line and reproduce the claim. Trace surrounding context (callers, definitions) through the graft graph per the `AGENTS.md` Graft section; raw `grep -rn` is the fallback for unindexed files only. One verdict per thread: confirmed / false positive (with proof: a passing test, a compiler result, a spec reference) / partially true. Never implement on an unvalidated finding.

## 3. Fix confirmed findings with TDD

One finding, one vertical slice: red test first, minimal green, then the next finding. Cover each fix in both directions: the red test proving the finding plus at least one test per failure envelope the touched code documents. Full gates before moving on: `mix test`, `mix credo --strict` clean on changed files, `mix dialyzer`. Before committing, run `mix format` on the changed files and re-verify with `mix format --check-formatted`. Two cautions earned the hard way:

- Hang-shaped bugs (deadlocks, blocked receives, wedged workers): run the red test under `timeout`, or the loop never returns.
- If the compiler disagrees with an edit, revert the file, re-apply the edit cleanly, and trust the compiler.

## 4. Reply to each thread

POST one reply per thread to `gh api repos/<owner>/<repo>/pulls/<number>/comments/<thread-id>/replies` (note: the replies segment hangs off the pull, not off the bare comment id — the bare form 404s). Confirmed → what changed, the covering test, the commit SHA; false positive → the proof, evidence only; partial → what was accepted and what was declined, with why.

## 5. Push

Push the branch (the PR updates itself and review re-runs on push). If any fix in this round alters user-visible behavior, add a CHANGELOG.md entry under `[Unreleased]` before pushing, and update the PR body if any replied-to description went stale.

Done when every unresolved thread has a fix-or-rebuttal on the branch, a posted reply, and the gates hold on the final tree.

## 6. File the findings

Record the round where future work can reach it: one `bd remember` entry per durable lesson (the bug, the fix, what the next ticket should know — not a copy of the per-thread log), and a bead comment on the originating ticket only when a finding changes that ticket's scope or acceptance. Refresh the repo context graph (`graft build`) after the code changed. Skip filing for one-off review mechanics with no reuse value.

Done when the lessons a future session would need are in beads memory and the graph is rebuilt.
