# Property-based testing with StreamData

Round-trip and invertibility properties (encode/decode identity, determinism,
message round-trips over 100+ generated inputs per type) sit alongside
example-based edge-case tests, so random testing finds the cases hand-written
examples miss and shrinking reduces failures to minimal inputs. Generators
must emit only values the spec accepts (generator ⊆ spec), proved by a
round-trip conformance test.

## Considered Options

- **Manual random testing**: rejected — no shrinking, hand-rolled generators,
  less maintainable.
- **Example-only testing for codecs**: rejected — framing edge cases are
  exactly what random generation finds.
