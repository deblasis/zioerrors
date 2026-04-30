//! End-to-end behavior tests for zioerrors.

const std = @import("std");
const zio = @import("zioerrors");

fn loadConfig(path: []const u8) !void {
    return zio.failf(error.FileNotFound, @src(), "loading config (path={s})", .{path});
}

fn refreshToken() !void {
    loadConfig("/etc/app.toml") catch |err| {
        return zio.fail(err, @src()).ctx("refreshing token").attr("user_id", @as(i64, 42)).err();
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
        // Source locations should reference the integration file, not
        // the library wrapper, since we passed @src() at the call site.
        try std.testing.expect(std.mem.indexOf(u8, out, "integration.zig") != null);
        return;
    };
    return error.UnexpectedSuccess;
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
    const e: anyerror = zio.fail(error.X, @src()).ctx("nope").err();
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
    const e: anyerror = zio.fail(error.ThreadFail, @src()).ctx("worker op").err();
    if (e != error.ThreadFail) return error.WrongError;
    if (ctx.frames.items.len != 1) return error.WrongFrameCount;
}

test "two threads have independent contexts" {
    const t1 = try std.Thread.spawn(.{}, threadEntry, .{std.testing.allocator});
    const t2 = try std.Thread.spawn(.{}, threadEntry, .{std.testing.allocator});
    t1.join();
    t2.join();
}

// OOM during capture must be swallowed: fail/failf return the original
// error value, the error set is never widened, no panic, no leaks. The
// resulting report is well-formed (possibly empty) and still prints.
//
// Two scenarios are covered:
//   1. Total starvation (fail_index = 0): every allocation fails, so the
//      frame stack stays empty and the report renders bare `error.X`.
//   2. Partial starvation (fail_index = 1): the initial frame append
//      may succeed but subsequent message/attr allocations fail. The
//      report still renders without crashing.

test "OOM during fail capture is swallowed under total starvation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var ctx = zio.Context.init(failing.allocator());
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    const e: anyerror = zio.fail(error.NotFound, @src())
        .ctx("loading config")
        .ctxf("loading {s}", .{"config"})
        .attr("path", "/etc/app.toml")
        .attr("size", @as(u64, 1024))
        .err();

    // Original error preserved, no widening.
    try std.testing.expectEqual(@as(anyerror, error.NotFound), e);

    // Same for the one-shot failf path.
    const e2: anyerror = zio.failf(error.X, @src(), "ctx {d}", .{42});
    try std.testing.expectEqual(@as(anyerror, error.X), e2);

    // Report must still render. Under total starvation no frame was
    // pushed, so the report degrades to the bare error form.
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zio.report(error.NotFound).format(&w);
    try std.testing.expectEqualStrings("error.NotFound", buf[0..w.end]);
}

test "OOM during fail capture is swallowed under partial starvation" {
    // Allow exactly one allocation to succeed, then fail. This exercises
    // the path where a frame may land but subsequent context-string and
    // attribute allocations cannot. The report must still render without
    // panic, regardless of how much (or how little) made it in.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var ctx = zio.Context.init(failing.allocator());
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    const e: anyerror = zio.fail(error.X, @src())
        .ctx("op")
        .attr("k1", "v1")
        .attr("k2", @as(i64, -7))
        .err();
    try std.testing.expectEqual(@as(anyerror, error.X), e);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zio.report(error.X).format(&w);
    const out = buf[0..w.end];

    // Report always begins with the bare error tag, whether or not a
    // frame survived the OOM.
    try std.testing.expect(std.mem.startsWith(u8, out, "error.X"));
}

test "report renders float and bool attrs in formatted output" {
    var c = zio.Context.init(std.testing.allocator);
    defer c.deinit();
    zio.install(&c);
    defer zio.uninstall();

    _ = zio.fail(error.X, @src()).ctx("op").attr("ratio", @as(f64, 3.14)).attr("flag", true);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zio.report(error.X).format(&w);
    const out = buf[0..w.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "ratio=3.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "flag=true") != null);
}

test "report with no attrs and no msg prints bare error and location" {
    var c = zio.Context.init(std.testing.allocator);
    defer c.deinit();
    zio.install(&c);
    defer zio.uninstall();

    _ = zio.fail(error.Timeout, @src());

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zio.report(error.Timeout).format(&w);
    const out = buf[0..w.end];
    // Just error name and source location, no message or attrs
    try std.testing.expect(std.mem.startsWith(u8, out, "error.Timeout"));
    try std.testing.expect(std.mem.indexOf(u8, out, "integration.zig") != null);
}

test "deep chain of five frames formats correctly" {
    var c = zio.Context.init(std.testing.allocator);
    defer c.deinit();
    zio.install(&c);
    defer zio.uninstall();

    inline for (0..5) |i| {
        const e = zio.failf(error.X, @src(), "layer {d}", .{i});
        try std.testing.expectEqual(@as(anyerror, error.X), e);
    }

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zio.report(error.X).format(&w);
    const out = buf[0..w.end];

    // Newest first
    try std.testing.expect(std.mem.indexOf(u8, out, "layer 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "layer 0") != null);
    // Four "caused by" lines for a five-deep chain
    var caused_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, out, search_from, "caused by")) |pos| {
        caused_count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), caused_count);
}

test "clear between operations resets for reuse" {
    var c = zio.Context.init(std.testing.allocator);
    defer c.deinit();
    zio.install(&c);
    defer zio.uninstall();

    // First operation
    _ = zio.fail(error.NotFound, @src()).ctx("first");
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    zio.clear();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);

    // Second operation on the same context
    _ = zio.fail(error.X, @src()).ctx("second").attr("k", "v");
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    try std.testing.expectEqualStrings("second", c.frames.items[0].msg);
}

test "unsigned attr renders correctly" {
    var c = zio.Context.init(std.testing.allocator);
    defer c.deinit();
    zio.install(&c);
    defer zio.uninstall();

    _ = zio.fail(error.X, @src()).ctx("op").attr("count", @as(u64, 42));

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zio.report(error.X).format(&w);
    const out = buf[0..w.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "count=42") != null);
}
