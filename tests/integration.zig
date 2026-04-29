//! End-to-end behavior tests for zioerrors.

const std = @import("std");
const zioerrors = @import("zioerrors");

test "module imports cleanly" {
    _ = zioerrors;
}
