const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = std.Build.LazyPath.relative("src/main.zig");

    // Dependencies
    const ziglyph_dep = b.dependency("ziglyph", .{
        .optimize = optimize,
        .target = target,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .optimize = optimize,
        .target = target,
    });
    const gap_buffer_dep = b.dependency("gap_buffer", .{
        .optimize = optimize,
        .target = target,
    });

    // Module
    const vaxis_mod = b.addModule("vaxis", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    vaxis_mod.addImport("ziglyph", ziglyph_dep.module("ziglyph"));
    vaxis_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    vaxis_mod.addImport("gap_buffer", gap_buffer_dep.module("gap_buffer"));

    // Examples
    const text_input_step = b.step("examples/text_input", "Run text_input.zig");

    const text_input = b.addExecutable(.{
        .name = "text_input",
        // Change this to the example you want to use!
        .root_source_file = std.Build.LazyPath.relative("examples/text_input.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_input.root_module.addImport("vaxis", vaxis_mod);

    const text_input_run = b.addRunArtifact(text_input);
    text_input_step.dependOn(&text_input_run.step);

    // Tests
    const tests_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ziglyph", ziglyph_dep.module("ziglyph"));
    tests.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    tests.root_module.addImport("gap_buffer", gap_buffer_dep.module("gap_buffer"));

    const tests_run = b.addRunArtifact(tests);
    b.installArtifact(tests);
    tests_step.dependOn(&tests_run.step);

    // Lints
    const lints_step = b.step("lint", "Run lints");

    const lints = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    lints_step.dependOn(&lints.step);
    b.default_step.dependOn(lints_step);

    // Docs
    const docs = b.addStaticLibrary(.{
        .name = "vaxis",
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    docs.root_module.addImport("vaxis", vaxis_mod);
    const build_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const build_docs_step = b.step("docs", "Build the vaxis library docs");
    build_docs_step.dependOn(&build_docs.step);
}
