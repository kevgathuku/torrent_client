# Torrent Client Constitution (Elixir)

How this codebase stays correct as it grows: pure logic decides, behaviours
perform effects, OTP supervisors recover. Every rule below is here because the
Clojure implementation paid for it in debugging time.

## Core Principles

### I. Pure Domain Layer

All torrent logic MUST be implemented as pure, deterministic functions with no
side effects:

- Piece selection algorithms MUST be pure functions of current state.
- Hash verification MUST be a pure transformation (bytes → boolean).
- State transitions MUST be expressed as `(state, event) → state`.
- Domain functions MUST NOT start processes, touch sockets, read files,
  read the clock, or call into other processes.
- Domain data structures MUST be immutable and serializable.
- The domain layer MUST NOT know it is running concurrently.

**Rationale**: pure logic is testable without mocks, deterministic under all
conditions, and reason-about-able independently of timing or I/O failures.

### II. Explicit Effect Boundaries

All side effects MUST sit behind explicit behaviour interfaces:

- Network I/O (peer connections, tracker communication, webseed fetches).
- Disk I/O (piece storage, resume-state persistence).
- Time (timestamps, delays, timeouts).
- Randomness (peer selection, protocol ids, backoff jitter).

Effect behaviours MUST:

- Be defined as `@behaviour` modules separate from their implementations.
- Receive their implementation at construction time (explicit opts), never
  hard-coded.
- Own their failure modes and report `{:ok, value} | {:error, reason}` tagged
  tuples.
- Live at the edges of the system, never in domain or coordination code.

Untrusted input (torrent files, tracker responses, peer bytes, webseed bodies)
MUST be validated in pure functions at the trust boundary before crossing an
effect:

- Path and name components MUST be confinement-checked before reaching the
  filesystem.
- Declared sizes MUST bound what is written, so stale state cannot survive
  a write.
- Validation failures MUST return `{:error, reason}` tuples, never raise.
- A rule enforced from two entry points MUST live in the function its callers
  share, so no caller can bypass it.

**Rationale**: explicit boundaries enable testing without real I/O,
deterministic integration tests with simulated time/network/disk, and clear
ownership of failure modes. Validating at the trust boundary keeps hostile
input from ever reaching an effect, and keeps the check itself pure and
unit-testable.

### III. Crash-Only Supervision

The system MUST embrace crash-only design with real OTP supervision:

- Workers MUST be allowed to crash on unexpected errors.
- Workers MUST NOT perform their own retries; retry policy belongs to
  supervisors.
- Every process MUST belong to a supervision tree with a defined restart
  strategy (`one_for_one` for independent peer workers, `rest_for_one` per
  torrent, a session supervisor above them).
- Restart intensity MUST bound churn; a repeatedly crashing child MUST NOT
  spin forever.
- Failure detection MUST be explicit (monitors, links), not implicit timeouts
  hidden in workers.
- Recovery MUST rebuild from durable state; no partial states allowed
  post-restart.

**Rationale**: crash-only design simplifies error handling, prevents cascading
failures through isolation, and lets the runtime — per-process heaps,
preemptive scheduling — contain faults the code never anticipated.

### IV. No Hidden State

All state MUST be explicitly passed or held by supervised processes:

- No application-global mutable state outside the supervision tree.
- No orphan processes or unsupervised background tasks.
- Per-torrent and per-peer processes MUST be addressable by identity
  (a registry keyed by info-hash, peer address), never by a single global
  name that permits only one instance.
- Configuration MUST be passed explicitly through start arguments, not read
  from ambient environment deep inside workers.
- True singletons (one listen socket, one peer id, one scheduler per daemon)
  MUST be named once at the top of the tree, never claimed per invocation.
- State changes MUST be traceable through explicit calls or messages.

**Rationale**: explicit state eliminates race conditions, enables reproducible
testing, and makes behaviour predictable and debuggable — including across a
remote shell attached to the running daemon.

### V. Testability Without I/O

The system MUST support comprehensive testing without real I/O:

- Domain logic MUST be covered by pure unit tests needing no mocks.
- Property-based tests SHOULD pin the pure, total functions (piece/block
  math, encoding round-trips); generators MUST be derived independently of
  the implementation.
- Integration tests MUST run deterministically with simulated time, network,
  and disk via mock behaviour implementations.
- Tests MUST NOT be flaky; non-determinism indicates an architecture
  violation.
- Crash/restart scenarios MUST be testable through supervisor test harnesses.
- Processes behind effect behaviours are excluded from property testing on
  principle — a generator cannot conjure timing or a network — and the
  exclusion MUST be recorded at the test site.

**Rationale**: I/O-free testing gives fast feedback, reliable CI, and
confidence under failure conditions including crashes.

## Layered Architecture

Four layers with strict one-way dependencies (lower layers never depend on
higher ones):

```
+---------------------+
|  Supervisor Layer   |  ← application tree, restart strategies, intensity
|---------------------|
| supervision trees   |
| restart policies    |
+----------+----------+
           |
           | supervises
           v
+---------------------+
| Coordination Layer  |  ← GenServers, message routing, backpressure
|---------------------|
| servers, demand     |
| message routing     |
+----------+----------+
           |
           | calls
           v
+---------------------+
| Protocol Layer      |  ← bencode, peer wire format, tracker protocol
|---------------------|
| encoding/decoding   |
| binary framing      |
+----------+----------+
           |
           | uses
           v
+---------------------+
| Domain Layer        |  ← pure torrent logic, no processes, no I/O
|---------------------|
| piece selection     |
| state transitions   |
+---------------------+
```

**Dependency Rules**:

- Domain MUST NOT depend on any layer above it.
- Protocol MAY depend on Domain only.
- Coordination MAY depend on Protocol and Domain.
- Supervision MAY depend on all layers below.
- Effect implementations are injected at the edges through behaviours, never
  called directly from domain or coordination logic.

## Cross-Cutting Rules

Learned the hard way; apply to every feature:

- **Wire bytes deserve bitstring syntax.** Parse binary protocols with binary
  pattern matching, never index arithmetic — framing code is the
  highest-risk code in the system.
- **Serve every declared source.** If the metadata names a source of bytes
  (trackers, DHT, webseeds), the client MUST be able to consume it; a source
  parsed and ignored is a download that stalls while others succeed.
- **Name every identity explicitly.** Registry keys, process names, and log
  fields carry the torrent or peer they belong to; bare, colliding names
  break multi-torrent operation.
- **Log data, not strings.** Emit structured log events with metadata through
  `Logger`; keep `IO.puts` out of workers.
- **Suffix predicates with `?` and keep effects visible** at the call site,
  so pure calls and effectful calls never look alike.
- **Do no work when a module loads.** No sockets, processes, or file reads at
  compile/load time, so code reloading stays safe.
- **Convert exceptions at the edge.** Effect code translates failures into
  `{:error, reason}` tuples; domain and protocol code returns error tuples
  and never raises.

## Development Workflow

### Code Review Gates

All changes MUST pass these gates before merge:

1. **Pure Domain Check**: domain modules start no processes and touch no
   I/O, clock, or environment.
2. **Effect Boundary Check**: side effects occur only in designated behaviour
   implementations.
3. **Supervision Check**: every process has an explicit supervisor and
   restart strategy.
4. **State Check**: no new global state; state flows are explicit.
5. **Test Check**: new code has corresponding tests; domain tests are pure.

### Testing Requirements

- Domain logic: pure unit tests, no mocks required.
- Pure total functions: property tests over their specs.
- Coordination logic: integration tests with simulated behaviours.
- Full system: end-to-end tests with doubles for all effects.
- Crash scenarios: supervisor tests that simulate process failures.

## Governance

This constitution supersedes all other architectural practices for this
project. Violations require explicit documentation in the implementation plan.

**Amendment Process**:

1. Propose amendment with rationale.
2. Assess impact on existing code and tests.
3. Document migration plan if breaking.
4. Update version according to semantic versioning:
   - MAJOR: principle removal or incompatible redefinition.
   - MINOR: new principle or material expansion.
   - PATCH: clarifications and non-semantic refinements.

**Compliance Review**:

- Every change SHOULD verify compliance with all five principles.
- Architecture violations MUST be flagged and justified or resolved.
- Periodic audits SHOULD verify no drift from constitutional principles.

**Version**: 1.0.0 | **Ratified**: 2026-10-20
