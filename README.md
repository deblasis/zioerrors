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
- `zioerrors.report(err)`: snapshot the chain for printing as `{f}`.
- `zioerrors.clear()`: drop frames, reset arena (call between independent operations).

## Examples

See `examples/cli/main.zig`. Run with `zig build run-example`.

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

**What if I forget to `clear()`?** Stale frames from a previous
failure will appear in a later report. The fix is to `clear()` at
each boundary.

**Allocation behavior?** Zero allocation on the happy path.
Allocations happen only inside `fail`, `ctx`, `ctxf`, and `attr`
paths, and go to the per-thread arena, which is reclaimed in O(1) by
`clear()`.

**What about OOM during context capture?** If the arena fails to
allocate while recording context, the frame or attribute is silently
dropped. The original error still propagates. Trade-off: the library
never widens your error set with its own `error.OutOfMemory`.

## Design

See `docs/superpowers/SEED.md` for the original brief and
`docs/superpowers/specs/2026-04-29-zioerrors-design.md` for the v0.1
design notes.

## Compatibility

- **Zig**: 0.16.0 (tracked in CI; earlier versions are not supported).
- **Platforms**: tested on Linux (x86_64), macOS (x86_64, aarch64), Windows (x86_64).
- **Breaking changes**: pinned to the Zig 0.16 stable release cycle. A major-version bump in Zig may require a major-version bump here.


## License

MIT. Copyright (c) 2026 Alessandro De Blasis.
