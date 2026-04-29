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

    /// Attach a typed attribute to the top frame. Accepts string
    /// slices, signed/unsigned integers, floats, and booleans. The
    /// key and any string value are heap-copied into the thread arena.
    pub fn attr(self: Builder, key: []const u8, value: anytype) Builder {
        const c = context.current orelse return self;
        if (c.frames.items.len == 0) return self;
        const arena_alloc = c.arena.allocator();

        const T = @TypeOf(value);
        const av: AttrValue = switch (@typeInfo(T)) {
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
                    const as_i64: i64 = @intCast(value);
                    break :blk .{ .int = as_i64 };
                }
                const as_u64: u64 = @intCast(value);
                break :blk .{ .uint = as_u64 };
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

/// One-shot fail with a comptime-formatted context. Equivalent to
/// `fail(err, src).ctxf(fmt, args).err()`.
pub fn failf(
    err_value: anyerror,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) anyerror {
    return fail(err_value, src).ctxf(fmt, args).err();
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

test "attr stores string, int, uint, float, bool typed values" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.X, here())
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

test "attr accepts string literal pointer" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    _ = fail(error.X, here()).ctx("op").attr("kind", "literal");
    try std.testing.expectEqualStrings("literal", c.frames.items[0].attrs[0].value.str);
}

test "failf records a single formatted frame" {
    var c = context.Context.init(std.testing.allocator);
    defer c.deinit();
    context.install(&c);
    defer context.uninstall();

    const e = failf(error.X, here(), "loading {s} (n={d})", .{ "config", 3 });
    try std.testing.expectEqual(@as(anyerror, error.X), e);
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    try std.testing.expectEqualStrings("loading config (n=3)", c.frames.items[0].msg);
}

test "attr is a no-op without installed context" {
    const b = fail(error.X, here()).attr("k", "v");
    try std.testing.expectEqual(@as(anyerror, error.X), b.err());
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
