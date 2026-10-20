# HTTP and UDP trackers with binary-safe encoding

Peer discovery speaks both HTTP announces (BEP 3) and UDP announces (BEP 15),
preferring compact peer format with dictionary fallback, falling back across
`announce-list` trackers on failure, and backing off exponentially with a
shared pure backoff helper. Binary URL fields are percent-encoded byte-wise
(RFC 3986); UDP integers are packed big-endian via binary pattern construction.

## Considered Options

- **Default query encoders for binary fields**: rejected — space-as-`+`
  conventions corrupt binary info-hashes; binary fields encode byte-wise.
- **Manual byte-shifting for UDP**: rejected — bitstring construction covers
  big-endian packing without the error surface.
- **Third-party binary/codec libraries**: rejected — overkill for two small,
  stable needs.
