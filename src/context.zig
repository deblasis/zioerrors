//! Thread-local error breadcrumb storage. Each thread owns a Context
//! holding an arena allocator and a stack of frames. Context strings
//! and string attributes are arena-allocated. Clear resets both.

const std = @import("std");
const Frame = @import("frame.zig").Frame;

/// Errors that may occur while capturing context. Out-of-memory during
/// capture is intentionally swallowed by the public API so that the
/// caller's error set is never widened.
pub const Error = error{OutOfMemory};

/// Per-thread context. Not thread-safe by design: each thread owns its
/// own instance. Caller is responsible for `init` once per thread and
/// `deinit` at thread exit.
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    frames: std.ArrayList(Frame),

    /// Initialize a fresh Context backed by the given allocator. The
    /// allocator is used to seed the arena and the frame stack.
    pub fn init(gpa: std.mem.Allocator) Context {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .frames = .empty,
        };
    }

    /// Release all resources held by this Context.
    pub fn deinit(self: *Context) void {
        self.frames.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Drop all frames and reset the arena. O(1) reclaim of the
    /// previous failure's context strings.
    pub fn clear(self: *Context) void {
        self.frames.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Per-thread Context pointer. Set by `install`, cleared by `uninstall`.
pub threadlocal var current: ?*Context = null;

/// Install the caller-owned Context as this thread's breadcrumb store.
/// The pointer must remain valid until `uninstall` (typically a stack
/// variable in main, or a heap allocation managed elsewhere).
pub fn install(ctx: *Context) void {
    current = ctx;
}

/// Tear down the calling thread's Context pointer. Does not free the
/// Context itself: caller is still responsible for `Context.deinit`.
pub fn uninstall() void {
    current = null;
}

test "Context init/deinit roundtrip with no frames" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);
}

test "Context clear is a no-op on empty state" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);
}

test "install and uninstall set the threadlocal pointer" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    install(&c);
    try std.testing.expect(current != null);
    uninstall();
    try std.testing.expect(current == null);
}

test "Context clear resets arena and frames after manual push" {
    var c = Context.init(std.testing.allocator);
    defer c.deinit();
    const arena_alloc = c.arena.allocator();
    const msg = try arena_alloc.dupe(u8, "hello");
    try c.frames.append(c.arena.child_allocator, .{
        .msg = msg,
        .attrs = &.{},
        .file = "x.zig",
        .line = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), c.frames.items.len);
    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.frames.items.len);
}
