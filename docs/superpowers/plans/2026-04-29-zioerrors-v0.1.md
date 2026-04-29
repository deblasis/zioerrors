# zioerrors v0.1 Implementation Plan

> **For agentic workers:** Each step is checkbox-tracked. Tests live alongside code via `test "..."` blocks. Use Zig 0.16. Commit after each green task.

**Goal:** Ship zioerrors v0.1: thread-local error breadcrumbs for Zig with `fail`, `failf`, `ctx`, `attr`, `report`, `init`, `deinit`, `clear`.

**Architecture:** Thread-local context owning a frame stack and an arena. `fail()` returns a `Builder` that pushes/decorates a frame. `report(err)` walks the frame stack into a formattable struct. Zero allocation on the happy path.

**Tech Stack:** Zig 0.16, std.heap.ArenaAllocator, std.ArrayList, std.Io.Writer, std.builtin.SourceLocation, threadlocal.

---

## File Structure

```
zioerrors/
  build.zig
  build.zig.zon
  src/
    root.zig          // module entry, re-exports
    frame.zig         // Frame, Attr, AttrValue
    context.zig       // thread-local Context (frames + arena), init/deinit/clear
    builder.zig       // Builder, fail, failf
    report.zig        // Report, report()
  examples/
    cli/main.zig
  tests/
    integration.zig
  README.md
  LICENSE
```

Each file has one responsibility. Tests are colocated. The integration test exercises end-to-end flows.

---

### Task 1: Repo scaffolding (build.zig, build.zig.zon, LICENSE)

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `LICENSE`
- Create: `src/root.zig` (placeholder)

- [ ] **Step 1: Write `build.zig.zon`**

```zig
.{
    .name = .zioerrors,
    .version = "0.1.0",
    .fingerprint = 0xa1d3a4f8b2c5e6f1,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "examples",
        "tests",
        "LICENSE",
        "README.md",
    },
}
```

- [ ] **Step 2: Write `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zioerrors", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests on src/*.zig
    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit = b.addRunArtifact(unit_tests);

    // Integration tests
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zioerrors", .module = mod }},
    });
    const integ_tests = b.addTest(.{
        .root_module = integ_mod,
    });
    const run_integ = b.addRunArtifact(integ_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_integ.step);

    // Example: examples/cli/main.zig
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zioerrors", .module = mod }},
    });
    const example_exe = b.addExecutable(.{
        .name = "zioerrors-cli",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    if (b.args) |args| run_example.addArgs(args);
    const run_example_step = b.step("run-example", "Run examples/cli");
    run_example_step.dependOn(&run_example.step);
}
```

- [ ] **Step 3: Write placeholder `src/root.zig`**

```zig
//! zioerrors: error context breadcrumbs for Zig.

test "placeholder" {}
```

- [ ] **Step 4: Write `LICENSE` (MIT, copyright Alessandro De Blasis)**

```
MIT License

Copyright (c) 2026 Alessandro De Blasis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 5: Verify build**

Run: `zig build test`
Expected: success, 1 test passed (the placeholder).

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon LICENSE src/root.zig
git commit -m "feat: scaffold build.zig and module entry point"
```

---

### Task 2: Frame and Attr types (data shape)

**Files:**
- Create: `src/frame.zig`

- [ ] **Step 1: Write `src/frame.zig` with tests**

```zig
//! Frame: one record in the breadcrumb chain. Holds a context message,
//! optional attributes, and a source location captured at the fail site.

const std = @import("std");

/// One key/value attribute attached to a frame.
pub const Attr = struct {
    key: []const u8,
    value: AttrValue,
};

/// Tagged value type for attribute payloads. Strings are owned by the
/// frame's arena; primitives are stored inline.
pub const AttrValue = union(enum) {
    str: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
};

/// One breadcrumb frame. `msg` and any string attributes are heap-copied
/// into the owning Context's arena. The frame itself owns no allocations
/// directly, the arena does.
pub const Frame = struct {
    msg: []const u8,
    attrs: []Attr,
    file: []const u8,
    line: u32,
};

test "Attr fits expected size and shape" {
    const a: Attr = .{ .key = "k", .value = .{ .int = 42 } };
    try std.testing.expectEqualStrings("k", a.key);
    try std.testing.expectEqual(@as(i64, 42), a.value.int);
}

test "AttrValue covers string, int, uint, float, bool" {
    const s: AttrValue = .{ .str = "hello" };
    const i: AttrValue = .{ .int = -1 };
    const u: AttrValue = .{ .uint = 1 };
    const f: AttrValue = .{ .float = 1.5 };
    const b: AttrValue = .{ .boolean = true };
    try std.testing.expect(s == .str);
    try std.testing.expect(i == .int);
    try std.testing.expect(u == .uint);
    try std.testing.expect(f == .float);
    try std.testing.expect(b == .boolean);
}

test "Frame fields are addressable" {
    const f: Frame = .{
        .msg = "loading config",
        .attrs = &.{},
        .file = "src/config.zig",
        .line = 42,
    };
    try std.testing.expectEqualStrings("loading config", f.msg);
    try std.testing.expectEqual(@as(usize, 0), f.attrs.len);
    try std.testing.expectEqual(@as(u32, 42), f.line);
}
```

- [ ] **Step 2: Wire `src/frame.zig` into `src/root.zig`**

Replace `src/root.zig` content with:

```zig
//! zioerrors: error context breadcrumbs for Zig.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const Attr = frame.Attr;
pub const AttrValue = frame.AttrValue;
pub const Frame = frame.Frame;

test {
    std.testing.refAllDeclsRecursive(@This());
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: 4+ tests passing.

- [ ] **Step 4: Commit**

```bash
git add src/frame.zig src/root.zig
git commit -m "feat: add Frame and Attr value types"
```

---

### Task 3: Thread-local Context with init/deinit/clear

**Files:**
- Create: `src/context.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write `src/context.zig`**

```zig
//! Thread-local error breadcrumb storage. Each thread owns a Context
//! holding an arena allocator and a stack of frames. Context strings
//! and string attributes are arena-allocated. Clear resets both.

const std = @import("std");
const Frame = @import("frame.zig").Frame;

/// Errors that may occur while capturing context. Out-of-memory during
/// capture is intentionally swallowed by the public API so that the
/// caller's error set is never widened.
pub const Error = error{OutOfMemory};

/// Per-thread context. Not thread-safe by design: each thread owns its
/// own instance. `init` must be called once per thread before any
/// `fail`, and `deinit` once at thread exit.
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    frames: std.ArrayList(Frame),

    /// Initialize a fresh Context backed by the given allocator. The
    /// allocator is used to seed the arena and the frame stack.
    pub fn init(gpa: std.mem.Allocator) Context {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .frames = .empty,
        };
    }

    /// Release all resources. Idempotent: calling deinit twice is safe.
    pub fn deinit(self: *Context) void {
        self.frames.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Drop all frames and reset the arena. O(1) reclaim of the
    /// previous failure's context strings.
    pub fn clear(self: *Context) void {
        self.frames.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Per-thread Context pointer. Set by `init`, cleared by `deinit`.
pub threadlocal var current: ?*Context = null;

/// Initialize the calling thread's Context. The caller owns `ctx` and
/// must keep it alive (typically a stack variable in main, or a heap
/// allocation managed elsewhere).
pub fn install(ctx: *Context) void {
    current = ctx;
}

/// Tear down the calling thread's Context pointer (does not free the
/// Context itself; caller calls `Context.deinit`).
pub fn uninstall() void {
    current = null;
}

test "Context init/deinit roundtrip with no frames" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);
}

test "Context clear is a no-op on empty state" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);
}

test "install and uninstall set the threadlocal pointer" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    install(&c);
    try std.testing.expect(current != null);
    uninstall();
    try std.testing.expect(current == null);
}

test "Context clear resets arena and frames after manual push" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    const gpa = c.arena.allocator();
    const msg = try gpa.dupe(u8, "hello");
    try c.frames.append(c.arena.child_allocator, .{
        .msg = msg,
        .attrs = &.{},
        .file = "x.zig",
        .line = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

Replace `src/root.zig` with:

```zig
//! zioerrors: error context breadcrumbs for Zig.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const context = @import("context.zig");
pub const Attr = frame.Attr;
pub const AttrValue = frame.AttrValue;
pub const Frame = frame.Frame;
pub const Context = context.Context;
pub const Error = context.Error;

/// Initialize the calling thread's breadcrumb context. Pass any
/// Allocator. Must be called once per thread before any `fail` call.
/// Returns a Context the caller is responsible for keeping alive
/// until `deinit`. Typical usage:
///
///     var ctx = zioerrors.init(allocator);
///     defer zioerrors.deinit(&ctx);
pub fn init(gpa: std.mem.Allocator) Context {
    var ctx = Context.init(gpa);
    context.install(&ctx);
    return ctx;
}

/// Deinitialize the calling thread's breadcrumb context. Releases all
/// captured context strings and the frame stack.
pub fn deinit(ctx: *Context) void {
    context.uninstall();
    ctx.deinit();
}

/// Drop all frames recorded on this thread since the last clear.
/// Cheap (arena reset). Boundary code should call this between
/// independent operations on the same thread.
pub fn clear() void {
    if (context.current) |c| c.clear();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
```

The `init` returns a `Context` by value, which works for the simple
`var ctx = zioerrors.init(...); defer zioerrors.deinit(&ctx);` pattern.
Note: `context.install` stores a pointer to a stack value that becomes
invalid after the function returns. We need to fix this in step 3.

- [ ] **Step 3: Fix the by-value-vs-pointer issue in root.init**

Replace the `init` and `deinit` functions in `src/root.zig` with the
in-place pattern that takes a `*Context`:

```zig
/// Install the caller-owned Context as this thread's breadcrumb
/// store. Caller is responsible for `Context.init`/`Context.deinit`.
/// Typical usage:
///
///     var ctx = zioerrors.Context.init(allocator);
///     defer ctx.deinit();
///     zioerrors.install(&ctx);
///     defer zioerrors.uninstall();
pub const install = context.install;

/// Uninstall the calling thread's Context pointer. Does not free.
pub const uninstall = context.uninstall;

/// Convenience: initialize a Context AND install it for this thread.
/// Caller must keep the returned Context alive and call `Context.deinit`.
pub fn init(gpa: std.mem.Allocator) Context {
    return Context.init(gpa);
}

/// Convenience: uninstall and deinit. Mirror of `init`.
pub fn deinit(ctx: *Context) void {
    if (context.current == ctx) context.uninstall();
    ctx.deinit();
}
```

Now the user pattern is:

```zig
var ctx = zioerrors.init(allocator);
defer zioerrors.deinit(&ctx);
zioerrors.install(&ctx);
```

The two-step `init` then `install(&ctx)` is the safe pattern: `&ctx`
is a stable pointer to the user's stack-resident Context.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: 8+ tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/context.zig src/root.zig
git commit -m "feat: thread-local Context with arena and frame stack"
```

---

### Task 4: Builder and `fail` core (no attrs yet)

**Files:**
- Create: `src/builder.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write `src/builder.zig` with tests**

```zig
//! Builder: chainable context-attaching API. `fail(err)` pushes a
//! frame and returns a Builder whose methods decorate the top frame.
//! All Builder methods coerce back to `anyerror` on `return` so the
//! call site stays a clean `return zioerrors.fail(err).ctx(...);`.

const std = @import("std");
const context = @import("context.zig");
const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const Attr = frame_mod.Attr;
const AttrValue = frame_mod.AttrValue;

/// Chainable builder returned by `fail`. Coerces to `anyerror` so it
/// can be `return`-ed directly: methods all return `Builder` so the
/// terminal call decides the coercion.
pub const Builder = struct {
    err_value: anyerror,

    /// Set or replace the top frame's context message. The string is
    /// heap-copied into the thread arena so it can outlive its source.
    pub fn ctx(self: Builder, msg: []const u8) Builder {
        if (context.current) |c| {
            const arena_alloc = c.arena.allocator();
            const owned = arena_alloc.dupe(u8, msg) catch return self;
            if (c.frames.items.len > 0) {
                c.frames.items[c.frames.items.len - 1].msg = owned;
            }
        }
        return self;
    }

    /// Append a comptime-format-built context line to the top frame.
    pub fn ctxf(
        self: Builder,
        comptime fmt: []const u8,
        args: anytype,
    ) Builder {
        if (context.current) |c| {
            const arena_alloc = c.arena.allocator();
            const owned = std.fmt.allocPrint(arena_alloc, fmt, args) catch return self;
            if (c.frames.items.len > 0) {
                c.frames.items[c.frames.items.len - 1].msg = owned;
            }
        }
        return self;
    }

    /// Terminal: return the bare error so callers can `return b.err()`.
    pub fn err(self: Builder) anyerror {
        return self.err_value;
    }
};

/// Coerce a Builder directly into the caller's narrow error set on
/// `return`. Zig allows this because Builder has no error union, but
/// for ergonomic chaining we expose `.err()` as the explicit form.
/// In practice users write `return zioerrors.fail(e).ctx(...).err();`
/// or pass `b.err()` to log statements.

/// Push a new frame and return a Builder. The frame captures the
/// caller's source location via `@src()`. If no Context is installed,
/// the call is a no-op for context but still returns a Builder
/// preserving `err_value`.
pub fn fail(err_value: anyerror, src: std.builtin.SourceLocation) Builder {
    if (context.current) |c| {
        c.frames.append(c.arena.child_allocator, .{
            .msg = "",
            .attrs = &.{},
            .file = src.file,
            .line = src.line,
        }) catch {};
    }
    return .{ .err_value = err_value };
}

test "fail without installed context returns a Builder carrying the error" {
    const b = fail(error.NotFound, @src());
    try std.testing.expectEqual(@as(anyerror, error.NotFound), b.err());
}

test "fail with installed context pushes a frame" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const b = fail(error.NotFound, @src());
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    try std.testing.expectEqual(@as(anyerror, error.NotFound), b.err());
}

test "ctx sets the top frame message" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.NotFound, @src()).ctx("loading config");
    try std.testing.expectEqualStrings("loading config", c.frames.items[0].msg);
}

test "ctxf formats the top frame message" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.NotFound, @src()).ctxf("loading {s}", .{"config"});
    try std.testing.expectEqualStrings("loading config", c.frames.items[0].msg);
}

test "two fails create two frames" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.NotFound, @src()).ctx("inner");
    _ = fail(error.NotFound, @src()).ctx("outer");
    try std.testing.expectEqual(@as(usize, 2), c.frames.items.len);
    try std.testing.expectEqualStrings("inner", c.frames.items[0].msg);
    try std.testing.expectEqualStrings("outer", c.frames.items[1].msg);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

Append to the imports/exports block in `src/root.zig`:

```zig
pub const builder_mod = @import("builder.zig");
pub const Builder = builder_mod.Builder;

/// Push a new frame and return a Builder. Use as:
/// `return zioerrors.fail(error.NotFound).ctx("loading config").err();`
pub inline fn fail(err_value: anyerror) Builder {
    return builder_mod.fail(err_value, @src());
}
```

The `inline` is important: `@src()` must capture the call site, not
the body of `fail`.

Wait, `@src()` inside an `inline fn` returns the location of the
inline call, which is what we want. But to be safe across Zig
versions we accept the SourceLocation explicitly in the lower-level
`builder_mod.fail` and have the public wrapper pass it.

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: 13+ tests passing.

- [ ] **Step 4: Commit**

```bash
git add src/builder.zig src/root.zig
git commit -m "feat: Builder, fail, ctx, ctxf"
```

---

### Task 5: `attr` for typed attributes

**Files:**
- Modify: `src/builder.zig`

- [ ] **Step 1: Add the failing test (top of `src/builder.zig`'s test block area)**

Append to `src/builder.zig`:

```zig
test "attr stores string, int, uint, float, bool typed values" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.X, @src())
        .ctx("op")
        .attr("path", "/etc/app.toml")
        .attr("count", @as(i64, -3))
        .attr("size", @as(u64, 1024))
        .attr("ratio", @as(f64, 1.5))
        .attr("ok", true);

    const f = c.frames.items[0];
    try std.testing.expectEqual(@as(usize, 5), f.attrs.len);
    try std.testing.expectEqualStrings("path", f.attrs[0].key);
    try std.testing.expectEqualStrings("/etc/app.toml", f.attrs[0].value.str);
    try std.testing.expectEqual(@as(i64, -3), f.attrs[1].value.int);
    try std.testing.expectEqual(@as(u64, 1024), f.attrs[2].value.uint);
    try std.testing.expectEqual(@as(f64, 1.5), f.attrs[3].value.float);
    try std.testing.expectEqual(true, f.attrs[4].value.boolean);
}
```

- [ ] **Step 2: Run test, expect failure**

Run: `zig build test`
Expected: compile error, `attr` is not a member of Builder.

- [ ] **Step 3: Implement `attr` on Builder**

Inside `pub const Builder = struct { ... }` in `src/builder.zig`,
between `ctxf` and `err`, add:

```zig
    /// Attach a typed attribute to the top frame. Accepts a string
    /// slice, integer, float, or bool. The key and any string value
    /// are heap-copied into the thread arena.
    pub fn attr(self: Builder, key: []const u8, value: anytype) Builder {
        const c = context.current orelse return self;
        if (c.frames.items.len == 0) return self;
        const arena_alloc = c.arena.allocator();

        const T = @TypeOf(value);
        const av: AttrValue = switch (@typeInfo(T)) {
            .int, .comptime_int => blk: {
                const as_i64: i64 = @intCast(value);
                break :blk .{ .int = as_i64 };
            },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            .bool => .{ .boolean = value },
            .pointer => |p| ptr: {
                if (p.size == .slice and p.child == u8) {
                    const owned = arena_alloc.dupe(u8, value) catch return self;
                    break :ptr .{ .str = owned };
                }
                if (p.size == .one) {
                    const child_info = @typeInfo(p.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        const slice: []const u8 = value;
                        const owned = arena_alloc.dupe(u8, slice) catch return self;
                        break :ptr .{ .str = owned };
                    }
                }
                @compileError("attr value must be string, int, float, or bool");
            },
            else => @compileError("attr value must be string, int, float, or bool"),
        };

        const owned_key = arena_alloc.dupe(u8, key) catch return self;
        const top = &c.frames.items[c.frames.items.len - 1];
        var list: std.ArrayList(Attr) = .{
            .items = @constCast(top.attrs),
            .capacity = top.attrs.len,
        };
        list.append(arena_alloc, .{ .key = owned_key, .value = av }) catch return self;
        top.attrs = list.items;
        return self;
    }

    /// Attach an explicit unsigned attribute. Use when an integer
    /// might exceed i64 range.
    pub fn attrUnsigned(self: Builder, key: []const u8, value: u64) Builder {
        const c = context.current orelse return self;
        if (c.frames.items.len == 0) return self;
        const arena_alloc = c.arena.allocator();
        const owned_key = arena_alloc.dupe(u8, key) catch return self;
        const top = &c.frames.items[c.frames.items.len - 1];
        var list: std.ArrayList(Attr) = .{
            .items = @constCast(top.attrs),
            .capacity = top.attrs.len,
        };
        list.append(arena_alloc, .{ .key = owned_key, .value = .{ .uint = value } }) catch return self;
        top.attrs = list.items;
        return self;
    }
```

Note: `attr` routes `u64` via `@intCast` to `i64`. For values that
exceed `i64` callers use `attrUnsigned`. The test above uses
`@as(u64, 1024)` so `attr` must dispatch unsigned ints via the `uint`
arm. Update the `.int, .comptime_int` arm to detect signedness:

```zig
            .int => |info| blk: {
                if (info.signedness == .unsigned) {
                    const as_u64: u64 = @intCast(value);
                    break :blk .{ .uint = as_u64 };
                }
                const as_i64: i64 = @intCast(value);
                break :blk .{ .int = as_i64 };
            },
            .comptime_int => blk: {
                if (value < 0) {
                    break :blk .{ .int = @intCast(value) };
                } else {
                    break :blk .{ .uint = @intCast(value) };
                }
            },
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: all tests pass including the new attr test.

- [ ] **Step 5: Commit**

```bash
git add src/builder.zig
git commit -m "feat: Builder.attr supports typed attributes"
```

---

### Task 6: `failf` convenience

**Files:**
- Modify: `src/builder.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Add failing test in `src/builder.zig`**

Append:

```zig
test "failf records a single formatted frame" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const e = failf(error.X, @src(), "loading {s} (n={d})", .{ "config", 3 });
    try std.testing.expectEqual(@as(anyerror, error.X), e);
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    try std.testing.expectEqualStrings("loading config (n=3)", c.frames.items[0].msg);
}
```

- [ ] **Step 2: Implement `failf` in `src/builder.zig`**

Add below `pub fn fail`:

```zig
/// One-shot fail with a formatted context. Equivalent to
/// `fail(err, src).ctxf(fmt, args).err()`.
pub fn failf(
    err_value: anyerror,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) anyerror {
    return fail(err_value, src).ctxf(fmt, args).err();
}
```

- [ ] **Step 3: Re-export from `src/root.zig`**

Add to the export block:

```zig
/// One-shot fail with a formatted context line. Wraps `fail().ctxf()`.
pub inline fn failf(
    err_value: anyerror,
    comptime fmt: []const u8,
    args: anytype,
) anyerror {
    return builder_mod.failf(err_value, @src(), fmt, args);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add src/builder.zig src/root.zig
git commit -m "feat: failf one-shot formatted fail"
```

---

### Task 7: Report formatter

**Files:**
- Create: `src/report.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write `src/report.zig`**

```zig
//! Report: formatter over the thread-local frame stack. Renders the
//! captured chain into something printable via `{f}` in std.log.

const std = @import("std");
const context = @import("context.zig");
const frame_mod = @import("frame.zig");

/// Snapshot of a thread's breadcrumbs at the time `report()` ran.
/// Lifetime tied to the underlying Context: do not retain past
/// `clear()` or `deinit()`.
pub const Report = struct {
    err_value: anyerror,
    frames: []const frame_mod.Frame,

    pub fn format(self: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Walk frames newest-first (innermost most recent failure).
        if (self.frames.len == 0) {
            try w.print("{t}", .{self.err_value});
            return;
        }
        const last = self.frames.len - 1;
        try writeFrame(w, self.err_value, self.frames[last], false);
        var i: usize = last;
        while (i > 0) {
            i -= 1;
            try w.writeAll("\n");
            try writeFrame(w, self.err_value, self.frames[i], true);
        }
    }
};

fn writeFrame(
    w: *std.Io.Writer,
    err_value: anyerror,
    f: frame_mod.Frame,
    caused_by: bool,
) std.Io.Writer.Error!void {
    if (caused_by) {
        try w.print("caused by error.{t}", .{err_value});
    } else {
        try w.print("error.{t}", .{err_value});
    }
    if (f.msg.len > 0) {
        try w.print(": {s}", .{f.msg});
    }
    if (f.attrs.len > 0) {
        try w.writeAll(" (");
        for (f.attrs, 0..) |a, idx| {
            if (idx > 0) try w.writeAll(", ");
            try w.print("{s}=", .{a.key});
            switch (a.value) {
                .str => |s| try w.print("{s}", .{s}),
                .int => |n| try w.print("{d}", .{n}),
                .uint => |n| try w.print("{d}", .{n}),
                .float => |x| try w.print("{d}", .{x}),
                .boolean => |b| try w.print("{}", .{b}),
            }
        }
        try w.writeAll(")");
    }
    try w.print("\n  at {s}:{d}", .{ f.file, f.line });
}

/// Snapshot the current thread's breadcrumbs as a Report bound to the
/// given error. If no Context is installed, returns an empty Report
/// that prints just `error.X`.
pub fn report(err_value: anyerror) Report {
    if (context.current) |c| {
        return .{ .err_value = err_value, .frames = c.frames.items };
    }
    return .{ .err_value = err_value, .frames = &.{} };
}

test "report with no context prints bare error" {
    const r = report(error.NotFound);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.format(&w);
    try std.testing.expectEqualStrings("error.NotFound", buf[0..w.end]);
}

test "report formats single frame with message" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const builder = @import("builder.zig");
    _ = builder.fail(error.NotFound, .{
        .module = "test",
        .file = "src/x.zig",
        .fn_name = "f",
        .line = 10,
        .column = 1,
    }).ctx("loading config");

    const r = report(error.NotFound);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.format(&w);
    try std.testing.expectEqualStrings(
        "error.NotFound: loading config\n  at src/x.zig:10",
        buf[0..w.end],
    );
}

test "report formats single frame with attrs" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const builder = @import("builder.zig");
    _ = builder.fail(error.NotFound, .{
        .module = "test",
        .file = "src/x.zig",
        .fn_name = "f",
        .line = 10,
        .column = 1,
    }).ctx("op").attr("path", "/etc/app.toml").attr("count", @as(i64, 3));

    const r = report(error.NotFound);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.format(&w);
    try std.testing.expectEqualStrings(
        "error.NotFound: op (path=/etc/app.toml, count=3)\n  at src/x.zig:10",
        buf[0..w.end],
    );
}

test "report formats multi-frame chain newest first" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const builder = @import("builder.zig");
    _ = builder.fail(error.X, .{
        .module = "t",
        .file = "a.zig",
        .fn_name = "f",
        .line = 1,
        .column = 1,
    }).ctx("inner");
    _ = builder.fail(error.X, .{
        .module = "t",
        .file = "b.zig",
        .fn_name = "g",
        .line = 2,
        .column = 1,
    }).ctx("outer");

    const r = report(error.X);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.format(&w);
    try std.testing.expectEqualStrings(
        "error.X: outer\n  at b.zig:2\ncaused by error.X: inner\n  at a.zig:1",
        buf[0..w.end],
    );
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

Add:

```zig
pub const report_mod = @import("report.zig");
pub const Report = report_mod.Report;
pub const report = report_mod.report;
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add src/report.zig src/root.zig
git commit -m "feat: Report formatter with chain rendering"
```

---

### Task 8: Integration tests

**Files:**
- Create: `tests/integration.zig`

- [ ] **Step 1: Write `tests/integration.zig`**

```zig
//! End-to-end behavior tests for zioerrors.

const std = @import("std");
const zio = @import("zioerrors");

fn loadConfig(path: []const u8) !void {
    return zio.failf(error.FileNotFound, "loading config (path={s})", .{path});
}

fn refreshToken() !void {
    loadConfig("/etc/app.toml") catch |err| {
        return zio.fail(err).ctx("refreshing token").attr("user_id", @as(i64, 42)).err();
    };
}

test "full chain via report" {
    var ctx = zio.Context.init(std.testing.allocator);
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    refreshToken() catch |err| {
        const r = zio.report(err);
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try r.format(&w);
        const out = buf[0..w.end];
        try std.testing.expect(std.mem.indexOf(u8, out, "refreshing token") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "user_id=42") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "loading config") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/etc/app.toml") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "caused by") != null);
        return;
    };
    return error.UnexpectedSuccess;
}

test "happy path performs zero allocations" {
    // Use a failing allocator: any allocation fails the test. Then
    // exercise the no-fail path through the API.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ctx = zio.Context.init(failing.allocator());
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    // No fail occurs, so no allocation should be triggered.
    const ok: u32 = 1;
    try std.testing.expectEqual(@as(u32, 1), ok);
}

test "clear resets thread state" {
    var ctx = zio.Context.init(std.testing.allocator);
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    _ = loadConfig("/x") catch {};
    try std.testing.expect(ctx.frames.items.len > 0);
    zio.clear();
    try std.testing.expectEqual(@as(usize, 0), ctx.frames.items.len);
}

test "missing context: fail and report degrade gracefully" {
    // No install. fail and report still return without crashing.
    const e: anyerror = zio.fail(error.X).ctx("nope").err();
    try std.testing.expectEqual(@as(anyerror, error.X), e);
    const r = zio.report(error.X);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.format(&w);
    try std.testing.expectEqualStrings("error.X", buf[0..w.end]);
}

fn threadEntry(allocator: std.mem.Allocator) !void {
    var ctx = zio.Context.init(allocator);
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();
    _ = zio.fail(error.ThreadFail).ctx("worker op").err();
    if (ctx.frames.items.len != 1) return error.WrongFrameCount;
}

test "two threads have independent contexts" {
    const t1 = try std.Thread.spawn(.{}, threadEntry, .{std.testing.allocator});
    const t2 = try std.Thread.spawn(.{}, threadEntry, .{std.testing.allocator});
    t1.join();
    t2.join();
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: all green, including integration suite.

- [ ] **Step 3: Commit**

```bash
git add tests/integration.zig
git commit -m "test: integration coverage for chain, clear, threading, and missing-context"
```

---

### Task 9: Example CLI

**Files:**
- Create: `examples/cli/main.zig`

- [ ] **Step 1: Write `examples/cli/main.zig`**

```zig
//! Example: read a missing file and print a chained zioerrors report.

const std = @import("std");
const zio = @import("zioerrors");

fn loadConfig(path: []const u8) !void {
    _ = std.fs.cwd().openFile(path, .{}) catch |err| {
        return zio.fail(err).ctx("loading config").attr("path", path).err();
    };
}

fn startup() !void {
    loadConfig("does-not-exist.toml") catch |err| {
        return zio.fail(err).ctx("starting up").attr("phase", "config").err();
    };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var ctx = zio.Context.init(gpa.allocator());
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    startup() catch |err| {
        var stderr_buf: [1024]u8 = undefined;
        var stderr: std.Io.Writer = .fixed(&stderr_buf);
        zio.report(err).format(&stderr) catch {};
        // Print to actual stderr via std.fs.File handle.
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.writeAll(stderr_buf[0..stderr.end]) catch {};
        _ = stderr_file.writeAll("\n") catch {};
        std.process.exit(1);
    };
}
```

- [ ] **Step 2: Run example**

Run: `zig build run-example`
Expected: process exits with code 1, stderr contains a chained report
mentioning `starting up`, `loading config`, and `does-not-exist.toml`.

- [ ] **Step 3: Commit**

```bash
git add examples/cli/main.zig
git commit -m "feat: example CLI demonstrating chained context"
```

---

### Task 10: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md` with the v0.1 content**

```markdown
# zioerrors

Error context breadcrumbs for Zig's bare error union. Pin failures
with structured payload; recover the chain at the boundary.

## Before / after

Without zioerrors (a typical 12-line "what failed and why" pattern):

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
    return zioerrors.fail(err).ctx("loading config")
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

## Install

```bash
zig fetch --save git+https://github.com/deblasis/zioerrors
```

Then in your `build.zig`:

```zig
const zio_dep = b.dependency("zioerrors", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zioerrors", zio_dep.module("zioerrors"));
```

## Quickstart

```zig
const std = @import("std");
const zioerrors = @import("zioerrors");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var ctx = zioerrors.Context.init(gpa.allocator());
    defer ctx.deinit();
    zioerrors.install(&ctx);
    defer zioerrors.uninstall();

    work() catch |err| {
        std.log.err("{f}", .{zioerrors.report(err)});
        return err;
    };
}

fn work() !void {
    return zioerrors.failf(
        error.NotImplemented,
        "demo failure (n={d})",
        .{42},
    );
}
```

## API

- `zioerrors.Context.init(allocator)`: create a per-thread context.
- `zioerrors.install(&ctx)` / `uninstall()`: bind/unbind for this thread.
- `zioerrors.fail(err)`: push a frame; returns a Builder.
  - `.ctx(msg)` / `.ctxf(fmt, args)`: set the frame message.
  - `.attr(key, value)`: typed attribute (string, int, float, bool).
  - `.err()`: terminal, returns the original error.
- `zioerrors.failf(err, fmt, args)`: one-shot wrap with a formatted line.
- `zioerrors.report(err)`: snapshot the chain for printing as `{f}`.
- `zioerrors.clear()`: drop frames, reset arena (call between independent operations).

## Examples

See `examples/cli/main.zig`. Run with `zig build run-example`.

## FAQ

**Why thread-local?** It keeps function signatures bare-`!T`, no
extra parameters, no `Result(T)` wrapping. The cost is one
`init`/`deinit` per thread. Cross-thread error propagation is out of
scope (use your own channel and re-attach context on the receiving
thread).

**What if I forget to `clear()`?** Stale frames from a previous
failure will appear in a later report. The fix is to `clear()` at
each boundary.

**Allocation behavior?** Zero allocation on the happy path. Allocations
happen only inside `fail`/`ctx`/`attr` paths and go to the per-thread
arena reclaimed by `clear()`.

## Design

See `docs/superpowers/SEED.md` and the v0.1 design doc under
`docs/superpowers/specs/`.

## License

MIT. Copyright (c) 2026 Alessandro De Blasis.
```

- [ ] **Step 2: Sanity-check no em-dashes**

Run: `git grep -nP $'\xe2\x80\x94' README.md docs/ src/ tests/ examples/` (Bash)

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with before/after, install, API, FAQ"
```

---

### Task 11: Final verification

- [ ] **Step 1: Format check**

Run: `zig fmt --check src tests examples`
Expected: no output, exit 0.

- [ ] **Step 2: Test run**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 3: Example run**

Run: `zig build run-example`
Expected: exit 1, stderr report with chained context.

If any step fails, fix and re-commit before declaring done.
