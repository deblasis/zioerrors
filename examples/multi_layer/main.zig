//! Example: multi-layer error handling across function boundaries.
//!
//! Shows how zioerrors works when errors propagate through three
//! layers of calls. Each layer adds its own context. The final
//! boundary formats and prints the full chain.

const std = @import("std");
const zio = @import("zioerrors");

fn readBytes(count: usize) ![]const u8 {
    return zio.fail(error.EndOfStream, @src())
        .ctx("reading bytes")
        .attr("requested", @as(u64, count))
        .err();
}

fn loadHeader() !void {
    _ = readBytes(4) catch |err| {
        return zio.fail(err, @src())
            .ctx("parsing header")
            .attr("format", "binary")
            .err();
    };
}

fn openFile(path: []const u8) !void {
    loadHeader() catch |err| {
        return zio.fail(err, @src())
            .ctx("opening file")
            .attr("path", path)
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

    openFile("data.bin") catch |err| {
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        zio.report(err).format(&w) catch {};
        std.debug.print("{s}\n", .{buf[0..w.end]});

        // Verify we got three layers of context.
        const out = buf[0..w.end];
        std.debug.assert(std.mem.indexOf(u8, out, "opening file") != null);
        std.debug.assert(std.mem.indexOf(u8, out, "parsing header") != null);
        std.debug.assert(std.mem.indexOf(u8, out, "reading bytes") != null);
        std.debug.assert(std.mem.indexOf(u8, out, "data.bin") != null);
    };
}
