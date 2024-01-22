const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.addModule("vaxis", .{ .root_source_file = .{ .path = "src/main.zig" } });

    const ziglyph = b.dependency("ziglyph", .{
        .optimize = optimize,
        .target = target,
    });
    vaxis.addImport("ziglyph", ziglyph.module("ziglyph"));

    const exe = b.addExecutable(.{
        .name = "vaxis",
        .root_source_file = .{ .path = "examples/text_input.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vaxis", vaxis);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("ziglyph", ziglyph.module("ziglyph"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
