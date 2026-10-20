# Set-based piece state with linear rarest-first selection

Piece state is a struct of persistent sets (needed, in-flight, verified), and
selection accepts peer availability as plain index sets — never bitstrings —
keeping the domain pure and testable. Selection is rarest-first by linear
frequency count with lowest-index tie-break; endgame is a pure predicate on
remaining pieces against a caller-supplied threshold, with duplicate in-flight
requests allowed.

## Considered Options

- **Bitstrings inside the domain or at the selection seam**: rejected —
  protocol-layer coupling in pure code, harder tests.
- **Maintained frequency table**: rejected — premature optimisation over a
  linear scan.
- **Random tie-break**: rejected — nondeterministic and harder to test.
- **Hard-coded endgame threshold**: rejected — policy belongs to the caller,
  mechanism here.
