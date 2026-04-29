# zioerrors v0.1 design

Date: 2026-04-29
Author: Alessandro De Blasis

## One-line pitch

Error-context breadcrumbs for Zig's bare error union: pin a failure with
structured context at the call site, recover the chain at the boundary.

## Problem

Zig errors are bare values. `error.NotFound` says nothing about what
wasn't found, where, or why. Today the choice is between:

1. Logging inline at every fail site (noise, lossy).
2. Maintaining a parallel context struct passed through every signature
   (boilerplate, viral).

zioerrors picks a third path: the function still returns the same bare
error union it always did, but the error value carries an attached
context chain that the boundary code can recover.

## Out of scope (v0.1)

Per seed:

- Panic / recovery hooks.
- Stack-walking beyond `@src()` capture.
- JSON serialization (deferred to ziolog integration).
- Cross-thread error propagation.

Additionally for v0.1:

- No symbolication via DWARF.
- No global allocator. Caller passes one.

## Design decisions

### Storage: thread-local stack indexed by error value

Each thread owns a `Context` (an array of frames) plus an arena
allocator. `fail(err)` pushes a frame keyed by the error. `report(err)`
walks the frames in reverse to format the chain. `clear()` resets the
stack and arena.

Rationale:

- Keeps function signatures bare-`!T`: `pub fn loadConfig(path) !Config`,
  not `Result(Config)`. Big ergonomics win.
- The "3-line API" promise from the zio-zig charter: callers add `.ctx`
  and `.attr` chains without changing return types or propagating extra
  parameters.
- Thread-local avoids cross-thread races. Cross-thread error
  propagation is explicitly out of scope.

Trade-off accepted: thread-local state must be initialized once per
thread (`zioerrors.init(allocator)`) and torn down at exit
(`zioerrors.deinit()`). Documented in README and asserted in debug
builds.

### Allocator policy

- Allocator passed to `init`. Stored in thread-local state.
- Zero allocation on the happy path. No `fail()`, no allocation.
- Allocation on the fail path: each frame heap-copies the context
  string and any string attribute values into a per-thread arena.
- `clear()` resets the arena: O(1) reclaim of all attached context.

This satisfies the seed's "zero-alloc happy path required, allocation
permitted only on the fail path" rule.

### Builder pattern, with `failf` convenience

Primary API:

```zig
return zioerrors.fail(err).ctx("loading config").attr("path", path);
```

`fail` returns a `Builder` value whose methods record into the top
frame. The builder ends in the original error: `return ... .err()` is
the explicit terminator, but most builder methods return the error
directly so chained calls still work as `return`-expressions.

Convenience:

```zig
return zioerrors.failf(err, "loading config (path={s})", .{path});
```

`failf` records a single context line built via `std.fmt`. No attrs.
Cheaper to type for one-off sites.

### Stack traces: `@src()` only

Each `fail` captures a `std.builtin.SourceLocation` via `@src()` and
stores `file` and `line` in the frame. `report()` formats them as
`at file.zig:42`.

No `captureStackTrace` for v0.1. Reasoning: the captured stack is
hard to symbolicate without DWARF, and the seed explicitly defers
"full stack-walking on Windows beyond what `std.debug` exposes". The
`@src()` capture is portable, alloc-free, and good enough for the
demo.

### Error set: structural

The library does not impose its own `error.X` set on callers. The
error returned by `fail(err)` is the same `err` the caller passed in.
The library has its own internal error set (`zioerrors.Error`) for
out-of-memory during context capture, but that error is swallowed in
release builds (frame is dropped) so `fail` never widens the caller's
error set.

Trade-off: we silently drop context if OOM hits during fail-path
allocation. Acceptable: the goal is diagnostics, not correctness, and
the original error still propagates.

### Multi-frame chains

Each `fail` pushes a new frame onto the thread's stack. A function
that wraps a downstream error calls `fail` again, producing a chain.
Frames are stored in push order; `report()` walks them and prints in
reverse (innermost first).

The frame is associated with the error value via the most recent
`fail()` call. We do not try to dedupe across different error values
on the same thread: if a function fails, swallows, recovers, and
later fails differently, the report only shows frames since the last
`clear()` matching the queried error.

For v0.1 the matching rule is the simplest one that works: `report(err)`
returns all frames recorded on the current thread since the last
`clear()`, regardless of which specific error value each frame was
associated with. The expected workflow is:

1. Boundary code calls `clear()` before each top-level operation.
2. Inner code does work, possibly calling `fail` zero or more times.
3. On failure the boundary calls `report(err)` once and prints it.

This rule keeps the implementation trivial and avoids any error-value
matching, at the cost of one constraint: callers must remember to
`clear()` between operations on the same thread, otherwise stale
frames from a previous failure would appear in a later report.
`clear()` is cheap (arena reset, frame stack truncate). The example
demonstrates the pattern.

### `report()` formatting

`report(err)` returns a `Report` struct with a `format` method. The
`err` argument is used for the leading `error.X:` line in the output;
the frame chain itself comes from the thread-local stack. It is
used as `{f}` in `std.log` formatters under Zig 0.16:

```
error.FileNotFound: loading config (path=/etc/app.toml)
  at src/config.zig:42
```

If multiple frames exist they print as a chain:

```
error.OutOfDate: refreshing token (user_id=42)
  at src/auth.zig:88
caused by error.FileNotFound: loading config (path=/etc/app.toml)
  at src/config.zig:42
```

## Public API surface

```zig
// lib.zig (re-exports)
pub const Error = error{OutOfMemory};
pub const Builder = @import("builder.zig").Builder;
pub const Report = @import("report.zig").Report;
pub const init = context.init;
pub const deinit = context.deinit;
pub const clear = context.clear;
pub const fail = builder.fail;
pub const failf = builder.failf;
pub const report = report_mod.report;
```

```zig
// builder.zig
pub const Builder = struct {
    err_value: anyerror,
    pub fn ctx(self: Builder, msg: []const u8) Builder;
    pub fn ctxf(self: Builder, comptime fmt: []const u8, args: anytype) Builder;
    pub fn attr(self: Builder, key: []const u8, value: anytype) Builder;
    pub fn err(self: Builder) anyerror;  // explicit terminator
};

pub fn fail(comptime err_value: anytype) Builder;  // captures @src()
pub fn failf(err_value: anytype, comptime fmt: []const u8, args: anytype) anyerror;
```

The `comptime` qualifier on `fail`'s err parameter is the trick that
lets the returned `Builder` type-erase to `anyerror` while the call
site can still `return zioerrors.fail(err).ctx(...);` with the
original narrower error type, because Zig coerces `anyerror` back to
the function's declared error set on return. (`anyerror` is allowed
inside the implementation, just not on public API boundaries; the
caller's signature is still a narrow `!T`.)

Internal modules (not re-exported in v0.1):

- `frame.zig`: `Frame` struct (msg, attrs, file, line) plus `Attr`
  tagged union (string / int / float / bool).
- `context.zig`: thread-local `Context` (frames + arena).

## File layout

```
zioerrors/
  build.zig
  build.zig.zon
  src/
    root.zig          // re-exports
    builder.zig       // Builder, fail, failf
    frame.zig         // Frame, Attr
    context.zig       // thread-local state
    report.zig        // Report, report()
  examples/
    cli/main.zig
  tests/
    integration.zig   // multi-frame, OOM, threading
  docs/superpowers/
    SEED.md
    specs/2026-04-29-zioerrors-design.md
    plans/2026-04-29-zioerrors-v0.1.md
  README.md
  LICENSE
```

Tests are colocated in each `src/*.zig` via `test "..."` blocks plus
an integration suite under `tests/`.

## Testing strategy

- Per-module: unit tests for every public function, every error path.
- Integration (`tests/integration.zig`):
  - Success path: no fail, no allocation, `report()` returns empty.
  - Single-frame fail with all attr types.
  - Multi-frame chain (3 levels).
  - OOM at fail time: original error still propagates, frame dropped.
  - `clear()` reclaims memory and resets state.
  - Thread isolation: two threads with independent state.
- Example (`examples/cli/main.zig`): reads a missing file, prints
  the chained report. Run via `zig build run-example`.

## Acceptance for v0.1

- `zig build test` green on Zig 0.16 (Windows verified locally).
- `zig fmt --check src` clean.
- All public decls have doc comments and explicit error sets.
- README has before/after demo, install snippet, minimal example,
  link back to this spec.
- One example under `examples/cli/main.zig`.
- One or more local commits, signed off as Alessandro. No remote push.

## Decisions left to a follow-up

- CI workflow (Linux/Windows/macOS matrix) is part of seed acceptance
  but the user prompt restricts this run to local commits only. CI
  file is included in the plan but marked as deferred unless time
  permits.
- Bench in `bench/` (seed asks for it). Same: include if time permits,
  otherwise track as v0.2.
