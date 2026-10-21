---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

## 1. Pick up the ticket

If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.

## 2. Branch

Create a new branch for the issue before changing anything (`git checkout -b <type>/<ticket>-<slug>`). Never implement directly on `main`.

## 3. Pre-checks

Before writing any code:

- Map the touched code paths with `graft` (`graft ask`, `graft callers`, `graft skeleton`) — know every caller and seam before changing a shared function.
- Pull the relevant decisions from beads memory — run `bd prime` for workflow context, then recall/search past notes, issue history, and ADRs. Prior tickets already settled naming, layering, and rejected alternatives.
- If any behaviour maps to a BEP, read the spec first and verify wire shapes, limits, and vocabulary against it — never implement protocol behaviour from memory.

## 4. TDD loop

Call the Skill tool with "tdd" where possible, at pre-agreed seams.

## 5. Done gates

An issue is done only when every gate below holds. Run the full suite once at the end, not after each slice.

- `mix test` passes.
- `mix credo --strict` reports no issues in the changed files.
- `mix dialyzer` passes (PLT is built; runs in seconds).
- `mix test --cover` passes with total coverage at or above the 80% threshold enforced in `mix.exs` (`test_coverage: [summary: [threshold: 80]]`), and every new or changed line is covered.
- Every new public function is covered in both directions: at least one test driving its success path and at least one driving each failure envelope it documents. A function whose tests only pass valid inputs has an unproven contract on exactly the paths callers branch on.
- Partial branch lines need judgement, not reflex fixes. Fail-closed branches on hostile input (guards, validators, error envelopes) get mutation-based generative specs: generate a valid input, break one field per mutation, assert rejection, plus one positive invariant (valid input always accepted). Prefer these over envelope-only example tests.
- Acceptable residues go in the test site, not in the PR body: uncovered lines or untested branches get a comment or explicit test at the test site explaining why.

## 6. Format and commit

Run `mix format` on every file you touched and confirm `mix format --check-formatted` passes on them. Never commit unformatted code.

Commit your work to the branch.

After committing, record durable lessons with `bd remember` (what broke, what the fix was, what the next ticket should know) and refresh the repo context graph with `graft build`.

## 7. Self-review with /code-review

Run the `code-review` skill against the branch (fixed point `main`) before opening the PR: Standards (repo conventions) and Spec (the beads issue as written, acceptance criteria included — every criterion must hold). Address what it finds — fix, then re-run the gates in step 5 — and note deliberate deviations for the PR body and a `bd remember` check.

As part of the review, judge whether the touched code could benefit from clojure.spec tests (fdef arg/ret contracts, generative checks on pure seams); where it would, add them, then re-run the gates in step 5.

## 8. Update docs and specs

This step covers product code changes only — skill and process changes skip it. Before opening the PR, keep the docs consistent with the change: search `docs/`, `doc/`, `CONTEXT.md`, and `docs/adr/` for statements this PR invalidates (removed APIs, changed seams, renamed concepts, altered behavior). If the change alters user-visible behavior, add a CHANGELOG.md entry under `[Unreleased]`. Update what the change actually breaks, in the same branch so docs and code land together. Scoped to broken assumptions only — never rewrite unrelated docs.

## 9. Push and open the PR

Push the branch (`git push -u origin <branch>`) and open a PR against `main` (`gh pr create`), body per the `pr` skill.
