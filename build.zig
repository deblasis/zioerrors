const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zioerrors", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests on src/*.zig
    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit = b.addRunArtifact(unit_tests);

    // Integration tests
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zioerrors", .module = mod }},
    });
    const integ_tests = b.addTest(.{
        .root_module = integ_mod,
    });
    const run_integ = b.addRunArtifact(integ_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_integ.step);

    // Example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zioerrors", .module = mod }},
    });
    const example_exe = b.addExecutable(.{
        .name = "zioerrors-cli",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    if (b.args) |args| run_example.addArgs(args);
    const run_example_step = b.step("run-example", "Run examples/cli");
    run_example_step.dependOn(&run_example.step);
}
