# Result tuples and validation at boundaries

Expected failures return `{:ok, value} | {:error, reason}` tuples and never
raise; public boundaries validate with explicit pure validators (plus
state-conservation properties in the piece domain), with validation failures
transformed into tagged error tuples carrying the cause.

## Considered Options

- **Exceptions for expected failures**: rejected — errors are values the
  coordinator branches on, not exceptional control flow.
