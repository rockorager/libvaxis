const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = b.path("src/main.zig");

    // Dependencies
    const zg_dep = b.dependency("zg", .{
        .optimize = optimize,
        .target = target,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .optimize = optimize,
        .target = target,
    });

    // Module
    const vaxis_mod = b.addModule("vaxis", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    vaxis_mod.addImport("code_point", zg_dep.module("code_point"));
    vaxis_mod.addImport("grapheme", zg_dep.module("grapheme"));
    vaxis_mod.addImport("DisplayWidth", zg_dep.module("DisplayWidth"));
    vaxis_mod.addImport("zigimg", zigimg_dep.module("zigimg"));

    // Examples
    const Example = enum {
        cli,
        counter,
        fuzzy,
        image,
        main,
        scroll,
        split_view,
        table,
        text_input,
        vaxis,
        view,
        vt,
    };
    const example_option = b.option(Example, "example", "Example to run (default: text_input)") orelse .text_input;
    const example_step = b.step("example", "Run example");
    const example = b.addExecutable(.{
        .name = "example",
        // future versions should use b.path, see zig PR #19597
        .root_source_file = b.path(
            b.fmt("examples/{s}.zig", .{@tagName(example_option)}),
        ),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("vaxis", vaxis_mod);

    const example_run = b.addRunArtifact(example);
    example_step.dependOn(&example_run.step);

    // Tests
    const tests_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("code_point", zg_dep.module("code_point"));
    tests.root_module.addImport("grapheme", zg_dep.module("grapheme"));
    tests.root_module.addImport("DisplayWidth", zg_dep.module("DisplayWidth"));
    tests.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));

    const tests_run = b.addRunArtifact(tests);
    b.installArtifact(tests);
    tests_step.dependOn(&tests_run.step);

    // Docs
    const docs_step = b.step("docs", "Build the vaxis library docs");
    const docs_obj = b.addObject(.{
        .name = "vaxis",
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
