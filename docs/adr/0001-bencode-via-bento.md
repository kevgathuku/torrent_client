# Bencode via the Bento library, not hand-rolled

Divergence from the Clojure ADR-0001 (hand-written recursive-descent parser):
bencode is decoded with the Bento library, producing its structs, with strict
BEP-3 validation (no `i-0e`, no leading zeros, truncated-input errors).
Hand-rolling a parser here buys nothing — the learning exercise already
happened on the Clojure side — but two duties transfer: the decoder MUST fully
validate input (key ordering, no leading zeros), because the info hash is only
valid over fully-validated input; and integers stay 64-bit range.

## Considered Options

- **Hand-written parser (Clojure ADR-0001)**: rejected — no new learning,
  extra code to own, same behavior Bento already provides.
- **Lax decoding**: rejected — an info hash over unvalidated bytes is a wrong
  identity hash.
