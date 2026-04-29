//! zioerrors: error context breadcrumbs for Zig.
//!
//! Pin a failure with structured context at the call site, then
//! recover the full chain at the boundary via `report`.
//!
//! Typical usage:
//!
//!     var ctx = zioerrors.Context.init(allocator);
//!     defer ctx.deinit();
//!     zioerrors.install(&ctx);
//!     defer zioerrors.uninstall();
//!
//!     work() catch |err| {
//!         std.log.err("{f}", .{zioerrors.report(err)});
//!         return err;
//!     };

const std = @import("std");

pub const frame = @import("frame.zig");
pub const context = @import("context.zig");
pub const builder_mod = @import("builder.zig");
pub const report_mod = @import("report.zig");

pub const Attr = frame.Attr;
pub const AttrValue = frame.AttrValue;
pub const Frame = frame.Frame;
pub const Context = context.Context;
pub const Error = context.Error;
pub const Builder = builder_mod.Builder;
pub const Report = report_mod.Report;

/// Snapshot the current thread's breadcrumbs as a Report bound to the
/// given error. The Report is printable via `{f}` in `std.fmt`, e.g.
/// `std.log.err("{f}", .{zioerrors.report(err)});`.
pub const report = report_mod.report;

/// Push a new breadcrumb frame for `err_value` and return a Builder.
/// Use as: `return zioerrors.fail(err).ctx("op").attr("k", v).err();`.
/// The Builder is a no-op if no Context is installed on this thread,
/// but the original error still propagates through `.err()`.
pub inline fn fail(err_value: anyerror) Builder {
    return builder_mod.fail(err_value, @src());
}

/// One-shot fail with a comptime-formatted context line. Wraps
/// `fail(err).ctxf(fmt, args).err()`.
pub inline fn failf(
    err_value: anyerror,
    comptime fmt: []const u8,
    args: anytype,
) anyerror {
    return builder_mod.failf(err_value, @src(), fmt, args);
}

/// Install the caller-owned Context as this thread's breadcrumb
/// store. Caller is responsible for `Context.init` and
/// `Context.deinit`.
pub const install = context.install;

/// Uninstall the calling thread's Context pointer. Does not free.
pub const uninstall = context.uninstall;

/// Drop all frames recorded on this thread since the last clear.
/// Cheap (arena reset). Boundary code should call this between
/// independent operations on the same thread.
pub fn clear() void {
    if (context.current) |c| c.clear();
}

test {
    _ = frame;
    _ = context;
    _ = builder_mod;
    _ = report_mod;
}

test "clear is safe with no installed context" {
    clear();
}
