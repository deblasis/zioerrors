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

/// Internal frame module. Access via the re-exported types below.
pub const frame = @import("frame.zig");
/// Internal context module.
pub const context = @import("context.zig");
/// Internal builder module.
pub const builder_mod = @import("builder.zig");
/// Internal report module.
pub const report_mod = @import("report.zig");

/// One key/value attribute attached to a frame.
pub const Attr = frame.Attr;
/// Tagged value type for attribute payloads.
pub const AttrValue = frame.AttrValue;
/// One breadcrumb frame in the error chain.
pub const Frame = frame.Frame;
/// Per-thread context holding the arena and frame stack.
pub const Context = context.Context;
/// Errors raised by the context module.
pub const Error = context.Error;
/// Chainable builder returned by `fail`.
pub const Builder = builder_mod.Builder;
/// Snapshot of a thread's breadcrumbs, formattable via `{f}`.
pub const Report = report_mod.Report;

/// Snapshot the current thread's breadcrumbs as a Report bound to the
/// given error. The Report is printable via `{f}` in `std.fmt`, e.g.
/// `std.log.err("{f}", .{zioerrors.report(err)});`.
pub const report = report_mod.report;

/// Push a new breadcrumb frame for `err_value` and return a Builder.
/// Pass `@src()` so the frame records the caller's source location:
///
///     return zioerrors.fail(err, @src()).ctx("op").attr("k", v).err();
///
/// Zig has no parameter defaults, so callers must pass `@src()`
/// explicitly. The cost is one token; the gain is that the frame
/// shows where the failure was raised, not where the wrapper lives.
/// The Builder is a no-op if no Context is installed on this thread,
/// but the original error still propagates through `.err()`.
pub fn fail(err_value: anyerror, src: std.builtin.SourceLocation) Builder {
    return builder_mod.fail(err_value, src);
}

/// One-shot fail with a comptime-formatted context line. Wraps
/// `fail(err, src).ctxf(fmt, args).err()`. Pass `@src()` for `src`.
pub fn failf(
    err_value: anyerror,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) anyerror {
    return builder_mod.failf(err_value, src, fmt, args);
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
