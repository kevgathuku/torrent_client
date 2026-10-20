# Hand-rolled wire codec over binary DSL libraries

Peer wire messages (BEP-3 core) are hand-written structs with explicit
bitstring `encode`/`decode`, not a binary DSL library. Nine frozen messages
don't justify a dependency: exact byte control and bespoke error envelopes
(`:truncated_message`, `:block_out_of_bounds`, `:unknown_message_id`) are
what the coordinator branches on, and a library would return generic parse
failures underneath hand-written cap/validation rules anyway.

## Considered Options

- **bin_struct**: declarative fields with parse/dump. Rejected — deletes
  ~60 lines but downgrades error precision and hides byte layout behind
  macros, against the constitution's bitstring-syntax rule.
- **Norm (spec-derived generators)**: rejected — StreamData generators
  already exist with round-trip conformance proving generator ⊆ spec.
- **New hex package generally**: rejected — AGENTS.md requires
  justification; line savings alone don't qualify.

## Revisit when

The protocol grows past BEP-3 core (BEP 10, fast extensions, DHT): message
count and nesting crossing that point is where a DSL pays for itself.
