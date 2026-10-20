# Single persistence seam with byte-faithful round-trip

One disk behaviour owns download persistence: encode (state to maps, binaries
to self-describing tagged hex maps), decode, and id-from-path (human-readable
string ID from the torrent filename, created once at start). CLI state helpers
are thin adapters over the same on-disk layout, and every load path decodes —
so a resumed download carries real bytes into handshake and piece
verification.

## Considered Options

- **Two seams (disk behaviour + CLI state with separate encodings)**:
  rejected — divergent IDs and serializations drift per caller.
- **Bare hex strings without decode**: rejected — resumed hashes reach
  byte-oriented code as strings and handshake/verification fail.
- **Schema-aware decode of known fields**: rejected — a field list rots; the
  tag is self-describing.
