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

pub const Attr = frame.Attr;
pub const AttrValue = frame.AttrValue;
pub const Frame = frame.Frame;
pub const Context = context.Context;
pub const Error = context.Error;

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
}

test "clear is safe with no installed context" {
    clear();
}
