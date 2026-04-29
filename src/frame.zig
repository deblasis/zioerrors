//! Frame: one record in the breadcrumb chain. Holds a context message,
//! optional attributes, and a source location captured at the fail
//! site. The frame's strings are owned by the parent Context's arena.

const std = @import("std");

/// One key/value attribute attached to a frame.
pub const Attr = struct {
    key: []const u8,
    value: AttrValue,
};

/// Tagged value type for attribute payloads. Strings are owned by the
/// frame's arena; primitives are stored inline.
pub const AttrValue = union(enum) {
    str: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
};

/// One breadcrumb frame. `msg` and any string attributes are heap-copied
/// into the owning Context's arena. The frame itself owns no allocations
/// directly: the arena does.
pub const Frame = struct {
    msg: []const u8,
    attrs: []Attr,
    file: []const u8,
    line: u32,
};

test "Attr fits expected size and shape" {
    const a: Attr = .{ .key = "k", .value = .{ .int = 42 } };
    try std.testing.expectEqualStrings("k", a.key);
    try std.testing.expectEqual(@as(i64, 42), a.value.int);
}

test "AttrValue covers string, int, uint, float, bool" {
    const s: AttrValue = .{ .str = "hello" };
    const i: AttrValue = .{ .int = -1 };
    const u: AttrValue = .{ .uint = 1 };
    const f: AttrValue = .{ .float = 1.5 };
    const b: AttrValue = .{ .boolean = true };
    try std.testing.expect(s == .str);
    try std.testing.expect(i == .int);
    try std.testing.expect(u == .uint);
    try std.testing.expect(f == .float);
    try std.testing.expect(b == .boolean);
}

test "Frame fields are addressable" {
    const f: Frame = .{
        .msg = "loading config",
        .attrs = &.{},
        .file = "src/config.zig",
        .line = 42,
    };
    try std.testing.expectEqualStrings("loading config", f.msg);
    try std.testing.expectEqual(@as(usize, 0), f.attrs.len);
    try std.testing.expectEqual(@as(u32, 42), f.line);
}
