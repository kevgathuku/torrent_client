---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.

Create a new branch for the issue before changing anything (`git checkout -b <type>/<ticket>-<slug>`). Never implement directly on `main`.

Pre-checks before writing any code:

- Map the touched code paths with `graft` (`graft ask`, `graft callers`, `graft skeleton`) — know every caller and seam before changing a shared function.
- Pull the relevant decisions from beads memory — run `bd prime` for workflow context, then recall/search past notes, issue history, and ADRs. Prior tickets already settled naming, layering, and rejected alternatives.
- If any behaviour maps to a BEP, read the spec first and verify wire shapes, limits, and vocabulary against it — never implement protocol behaviour from memory.

Call the Skill tool with "tdd" where possible, at pre-agreed seams.

An issue is done only when every gate below holds. Run the full suite once at the end, not after each slice.

- `mix test` passes.
- `mix credo --strict` reports no issues in the changed files.
- `mix dialyzer` passes (PLT is built; runs in seconds).
- `mix test --cover` passes with total coverage at or above the 80% threshold enforced in `mix.exs` (`test_coverage: [summary: [threshold: 80]]`), and every new or changed line is covered.
- Every new public function is covered in both directions: at least one test driving its success path and at least one driving each failure envelope it documents. A function whose tests only pass valid inputs has an unproven contract on exactly the paths callers branch on.
- Partial branch lines need judgement, not reflex fixes. Fail-closed branches on hostile input (guards, validators, error envelopes) get mutation-based generative specs: generate a valid input, break one field per mutation, assert rejection, plus one positive invariant (valid input always accepted). Prefer these over envelope-only example tests.
- Acceptable residues go in the test site, not in the PR body: uncovered lines or untested branches get a comment or explicit test at the test site explaining why.

Once done, call the Skill tool with "code-review" to review the work.

Before committing, run `mix format` on every file you touched and confirm `mix format --check-formatted` passes on them. Never commit unformatted code.

Commit your work to the branch.

After committing, record durable lessons with `bd remember` (what broke, what the fix was, what the next ticket should know) and refresh the repo context graph with `graft build`.

Push the branch (`git push -u origin <branch>`) and open a PR against `main` (`gh pr create`). The PR body points at the issue tracker state; coverage residues and accepted gaps live at the test site, not in the PR body.
