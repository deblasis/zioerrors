//! zioerrors: error context breadcrumbs for Zig.
//!
//! Pin a failure with structured context at the call site, then
//! recover the full chain at the boundary via `report`.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const Attr = frame.Attr;
pub const AttrValue = frame.AttrValue;
pub const Frame = frame.Frame;

test {
    _ = frame;
}
