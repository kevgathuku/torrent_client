# Peer wire as structs plus a pure state machine

Handshake and all nine BEP-3 messages are structs built/parsed with binary
pattern matching, and per-peer posture (choking, interest, availability)
evolves through a pure `(state, event) → state` function. The protocol layer
never sees TCP framing or stream reassembly, caps blocks at 16 KiB, ignores
BEP 10 / fast-extension messages (preserving reserved bytes), and keeps
bitfields behind an immutable abstraction.

## Considered Options

- **Binary parsing libraries**: rejected — bitstring syntax already covers
  framing with less to own.
- **BEP 10 and fast extensions**: explicitly out of scope — core transfer
  first.
