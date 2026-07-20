# zioerrors

Error context breadcrumbs for Zig's bare error union. Pin failures
with structured payload, recover the chain at the boundary. Inspired
by Rust's `anyhow` / `eyre` and Go's wrapped errors.

## Before / after

Without zioerrors (a typical "what failed and why" pattern):

```zig
const file = std.fs.cwd().openFile(path, .{}) catch |err| {
    std.log.err(
        "loading config failed: {s} (path={s}, user_id={d})",
        .{ @errorName(err), path, user_id },
    );
    return err;
};
```

With zioerrors (4 lines, structured, chains automatically):

```zig
const file = std.fs.cwd().openFile(path, .{}) catch |err| {
    return zioerrors.fail(err, @src()).ctx("loading config")
        .attr("path", path).attr("user_id", user_id).err();
};
```

At the boundary:

```zig
work() catch |err| {
    std.log.err("{f}", .{zioerrors.report(err)});
    return err;
};
```

Output:

```
error.FileNotFound: loading config (path=/etc/app.toml, user_id=42)
  at src/config.zig:42
```

If a wrapping function adds more context, the chain is preserved:

```
error.FileNotFound: starting up (phase=config)
  at src/app.zig:23
caused by error.FileNotFound: loading config (path=/etc/app.toml)
  at src/config.zig:42
```

Each frame prints the error it was raised for, so a layer that turns one
error into another says so:

```
error.ConfigInvalid: loading config (path=/etc/app.toml)
  at src/config.zig:42
caused by error.FileNotFound: reading file
  at src/io.zig:11
```

## Chain lifetime

The breadcrumbs live on a thread-local stack, so it matters when a chain
starts and ends.

- Every `fail` pushes onto the current chain, which is how a wrapped
  error accumulates layers as it propagates.
- `report` ends the chain. The frames stay readable until the next
  `fail` on that thread, which drops them and starts a new chain. So a
  forgotten `clear` cannot make one operation's frames show up under the
  next operation's error. Do not hold a `Report` across a later `fail`:
  it borrows the context's memory, which gets reused.
- `clear()` ends the chain right away. You only need it when an
  operation fails, is handled without a report, and the thread then goes
  on to unrelated work. Those frames have nothing else to end them.

## Install

```bash
zig fetch --save git+https://github.com/deblasis/zioerrors
```

Then in your `build.zig`:

```zig
const zio_dep = b.dependency("zioerrors", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zioerrors", zio_dep.module("zioerrors"));
```

Requires Zig 0.16.

## Quickstart

```zig
const std = @import("std");
const zioerrors = @import("zioerrors");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var ctx = zioerrors.Context.init(gpa.allocator());
    defer ctx.deinit();
    zioerrors.install(&ctx);
    defer zioerrors.uninstall();

    work() catch |err| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        zioerrors.report(err).format(&w) catch {};
        std.debug.print("{s}\n", .{buf[0..w.end]});
        return err;
    };
}

fn work() !void {
    return zioerrors.failf(
        error.NotImplemented,
        @src(),
        "demo failure (n={d})",
        .{42},
    );
}
```

## API

- `zioerrors.Context.init(allocator)`: create a per-thread context.
- `zioerrors.install(&ctx)` / `uninstall()`: bind / unbind for this thread.
- `zioerrors.fail(err, @src())`: push a frame, returns a Builder.
  - `.ctx(msg)` / `.ctxf(fmt, args)`: set the frame message.
  - `.attr(key, value)`: typed attribute (string, signed int, unsigned int, float, bool).
  - `.err()`: terminal, returns the original error.
- `zioerrors.failf(err, @src(), fmt, args)`: one-shot wrap with a formatted line.
- `zioerrors.report(err)`: snapshot the chain for printing as `{f}`. Ends the chain.
- `zioerrors.clear()`: drop frames, reset arena. For failures that are handled without a report.

## Examples

- `examples/cli/main.zig`: the boundary pattern. Run with `zig build run-example`.
- `examples/multi_layer/main.zig`: context added across three call layers.
  Run with `zig build run-example-multi-layer`.

## FAQ

**Why thread-local?** It keeps function signatures bare-`!T`: no
extra parameters, no `Result(T)` wrapping. The cost is one
`Context.init` / `Context.deinit` per thread plus calling `install`
once. Cross-thread error propagation is out of scope (use your own
channel and re-attach context on the receiving thread).

**Why must I pass `@src()`?** Zig has no parameter defaults and
`inline fn` does not capture the caller's `@src()`. Passing it
explicitly costs one token per call but means the recorded frame
points at your code, not at the library wrapper.

**What if I forget to `clear()`?** Usually nothing, because `report`
ends the chain and the next `fail` starts a new one. The case that
still needs `clear()` is a failure you handle without reporting it:
nothing tells the library that operation is over, so those frames are
still on the stack when the next failure starts stacking on top of
them. See "Chain lifetime" above.

**Allocation behavior?** Zero allocation on the happy path.
Allocations happen only inside `fail`, `ctx`, `ctxf`, and `attr`
paths, and go to the per-thread arena, which is reclaimed in O(1) by
`clear()`.

**What about OOM during context capture?** If the arena fails to
allocate while recording context, the frame or attribute is silently
dropped. The original error still propagates. Trade-off: the library
never widens your error set with its own `error.OutOfMemory`.

## Compatibility

- **Zig**: 0.16.0 (tracked in CI; earlier versions are not supported).
- **Platforms**: tested on Linux (x86_64), macOS (x86_64, aarch64), Windows (x86_64).
- **Breaking changes**: pinned to the Zig 0.16 stable release cycle. A major-version bump in Zig may require a major-version bump here.


## License

MIT. Copyright (c) 2026 Alessandro De Blasis.
