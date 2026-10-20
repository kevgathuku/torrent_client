---
name: pr
description: "Use when writing a PR body."
---

Write the PR body in this shape:

```markdown
Implements <bead-id>.

<one paragraph: what this unifies/builds/fixes and why, in domain language>

## What changed

- **<Area>**: <what changed and why; include what was verified failing first or round-tripped>
- **<Area>**: ...

## Verification

TDD throughout (red before green per slice): `mix test` — <N> tests, <M> properties, 0 failures. <specific checks: e.g. no bare X remains in lib/, gate outputs>
```

## Rules

- First line always names the task: `Implements <bead-id>.` (or `Closes #N` for GitHub-tracked work). No other preamble.
- **What changed** leads each bullet with the area in bold, then the change plus the evidence behind it (failing-first test, round-trip proof, interop check). Prose brief; bullets, not paragraphs.
- **Verification** states the loop (TDD red→green), the exact suite numbers, and any locus-specific checks (linter, dialyzer, format, coverage vs the gate).
- Residues and accepted gaps live at the test site, not here — except epic-level status the next ticket needs (e.g. total coverage vs the 80% gate), which gets one line.
- Keep the project's domain vocabulary; skip screenshots unless the change is visual.
