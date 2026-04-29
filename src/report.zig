//! Report: formatter over the thread-local frame stack. Renders the
//! captured chain into something printable via `{f}` in std.log.

const std = @import("std");
const context = @import("context.zig");
const frame_mod = @import("frame.zig");

/// Snapshot of a thread's breadcrumbs at the time `report()` ran.
/// Lifetime is tied to the underlying Context: do not retain past
/// `clear()` or `Context.deinit()`.
pub const Report = struct {
    err_value: anyerror,
    frames: []const frame_mod.Frame,

    /// std.fmt format method. Use as `std.log.err("{f}", .{report(err)});`.
    pub fn format(self: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.frames.len == 0) {
            try w.print("error.{t}", .{self.err_value});
            return;
        }
        // Walk frames newest-first (innermost is the most recent
        // failure pushed onto the stack).
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
                .boolean => |bv| try w.print("{}", .{bv}),
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

const test_src: std.builtin.SourceLocation = .{
    .module = "test",
    .file = "src/x.zig",
    .fn_name = "f",
    .line = 10,
    .column = 1,
};

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
    _ = builder.fail(error.NotFound, test_src).ctx("loading config");

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
    _ = builder.fail(error.NotFound, test_src)
        .ctx("op")
        .attr("path", "/etc/app.toml")
        .attr("count", @as(i64, 3));

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
    const inner_src: std.builtin.SourceLocation = .{
        .module = "t",
        .file = "a.zig",
        .fn_name = "f",
        .line = 1,
        .column = 1,
    };
    const outer_src: std.builtin.SourceLocation = .{
        .module = "t",
        .file = "b.zig",
        .fn_name = "g",
        .line = 2,
        .column = 1,
    };
    _ = builder.fail(error.X, inner_src).ctx("inner");
    _ = builder.fail(error.X, outer_src).ctx("outer");

    const r = report(error.X);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.format(&w);
    try std.testing.expectEqualStrings(
        "error.X: outer\n  at b.zig:2\ncaused by error.X: inner\n  at a.zig:1",
        buf[0..w.end],
    );
}
