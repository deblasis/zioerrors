//! Example: simulate a missing file and print a chained zioerrors report.
//!
//! Demonstrates the boundary pattern:
//!
//!   1. Boundary code installs a Context for the thread.
//!   2. Inner code calls `fail` / `failf` to attach context to errors.
//!   3. Boundary catches and prints the chain via `report`.

const std = @import("std");
const zio = @import("zioerrors");

fn loadConfig(path: []const u8) !void {
    // Simulate a missing-file error so the example does not depend on
    // any particular Zig stdlib I/O surface.
    return zio.fail(error.FileNotFound, @src())
        .ctx("loading config")
        .attr("path", path)
        .err();
}

fn startup() !void {
    loadConfig("does-not-exist.toml") catch |err| {
        return zio.fail(err, @src())
            .ctx("starting up")
            .attr("phase", "config")
            .err();
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var ctx = zio.Context.init(gpa.allocator());
    defer ctx.deinit();
    zio.install(&ctx);
    defer zio.uninstall();

    startup() catch |err| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        zio.report(err).format(&w) catch {};
        std.debug.print("{s}\n", .{buf[0..w.end]});
        std.process.exit(1);
    };
}
