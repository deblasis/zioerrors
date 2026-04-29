//! Builder: chainable context-attaching API. `fail(err, src)` pushes a
//! frame and returns a Builder whose methods decorate the top frame.
//! All methods coerce back to `anyerror` via `.err()` so the call site
//! stays a clean `return zioerrors.fail(err).ctx("...").err();`.

const std = @import("std");
const context = @import("context.zig");
const frame_mod = @import("frame.zig");
const Frame = frame_mod.Frame;
const Attr = frame_mod.Attr;
const AttrValue = frame_mod.AttrValue;

/// Chainable builder returned by `fail`. Each method records into the
/// top frame on the calling thread's Context. If no Context is
/// installed, the methods are no-ops (the original error still
/// propagates).
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

    /// Set or replace the top frame's context message via a comptime
    /// format string.
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

    /// Terminal: returns the bare error so callers can write
    /// `return zioerrors.fail(err).ctx("...").err();`.
    pub fn err(self: Builder) anyerror {
        return self.err_value;
    }
};

/// Push a new frame and return a Builder. The frame captures the
/// caller-provided source location. If no Context is installed, no
/// frame is pushed but the Builder still carries the error.
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

fn here() std.builtin.SourceLocation {
    return @src();
}

test "fail without installed context returns a Builder carrying the error" {
    const b = fail(error.NotFound, here());
    try std.testing.expectEqual(@as(anyerror, error.NotFound), b.err());
}

test "fail with installed context pushes a frame" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const b = fail(error.NotFound, here());
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    try std.testing.expectEqual(@as(anyerror, error.NotFound), b.err());
}

test "ctx sets the top frame message" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.NotFound, here()).ctx("loading config");
    try std.testing.expectEqualStrings("loading config", c.frames.items[0].msg);
}

test "ctxf formats the top frame message" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.NotFound, here()).ctxf("loading {s}", .{"config"});
    try std.testing.expectEqualStrings("loading config", c.frames.items[0].msg);
}

test "two fails create two frames in push order" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.NotFound, here()).ctx("inner");
    _ = fail(error.NotFound, here()).ctx("outer");
    try std.testing.expectEqual(@as(usize, 2), c.frames.items.len);
    try std.testing.expectEqualStrings("inner", c.frames.items[0].msg);
    try std.testing.expectEqualStrings("outer", c.frames.items[1].msg);
}
