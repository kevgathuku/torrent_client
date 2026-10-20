# CLI persistence through the disk behaviour

All CLI byte movement (save/load/delete call sites: pause, resume, status,
stop, start) goes through the disk behaviour built at startup, so the CLI
and orchestration share one transport, one filename scheme, and one error
story. CLI helpers keep only the state-dir default, path construction, and
most-recent scanning — dir-scanning by recency has no behaviour equivalent,
so the keeper scans while the behaviour reads. Commands map a corrupt or
missing record to nil (the long-standing missing-state UX); save/delete
failures report and exit nonzero. Refines ADR-0009's two-adapter arrangement.

## Considered Options

- **Keep a CLI-side transport alongside the behaviour**: rejected — the
  filename scheme and error semantics drift per caller.
- **Move recency scanning into the behaviour**: rejected — a new callback
  for one CLI fallback; the keeper scans, the behaviour reads.
- **One shared literal for the filename scheme**: rejected — the behaviour
  cannot depend on the CLI layer; the keeper names the scheme and a test
  pins the behaviour's agreement with it.
