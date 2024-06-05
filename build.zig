const std = @import("std");

pub fn build(b: *std.Build) void {
    const include_libxev = b.option(bool, "libxev", "Enable support for libxev library (default: true)") orelse true;
    const include_images = b.option(bool, "images", "Enable support for images (default: true)") orelse true;
    const include_nvim = b.option(bool, "nvim", "Enable support for the neovim widget (default: false)") orelse true;
    const include_text_input = b.option(bool, "text_input", "Enable support for the TextInput widget (default: true)") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "libxev", include_libxev);
    options.addOption(bool, "images", include_images);
    options.addOption(bool, "nvim", include_nvim);
    options.addOption(bool, "text_input", include_text_input);

    const options_mod = options.createModule();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = b.path("src/main.zig");

    // Dependencies
    const zg_dep = b.dependency("zg", .{
        .optimize = optimize,
        .target = target,
    });
    const zigimg_dep = if (include_images) b.lazyDependency("zigimg", .{
        .optimize = optimize,
        .target = target,
    }) else null;
    const gap_buffer_dep = if (include_text_input) b.lazyDependency("gap_buffer", .{
        .optimize = optimize,
        .target = target,
    }) else null;
    const znvim_dep = if (include_nvim) b.lazyDependency("znvim", .{
        .optimize = optimize,
        .target = target,
    }) else null;
    const xev_dep = if (include_libxev) b.lazyDependency("libxev", .{
        .optimize = optimize,
        .target = target,
    }) else null;

    // Module
    const vaxis_mod = b.addModule("vaxis", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    vaxis_mod.addImport("code_point", zg_dep.module("code_point"));
    vaxis_mod.addImport("grapheme", zg_dep.module("grapheme"));
    vaxis_mod.addImport("DisplayWidth", zg_dep.module("DisplayWidth"));
    if (zigimg_dep) |dep| vaxis_mod.addImport("zigimg", dep.module("zigimg"));
    if (gap_buffer_dep) |dep| vaxis_mod.addImport("gap_buffer", dep.module("gap_buffer"));
    if (znvim_dep) |dep| vaxis_mod.addImport("znvim", dep.module("znvim"));
    if (xev_dep) |dep| vaxis_mod.addImport("xev", dep.module("xev"));
    vaxis_mod.addImport("build_options", options_mod);

    // Examples
    const Example = enum {
        cli,
        image,
        main,
        nvim,
        table,
        text_input,
        vaxis,
        xev,
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
    if (xev_dep) |dep| example.root_module.addImport("xev", dep.module("xev"));

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
    if (zigimg_dep) |dep| tests.root_module.addImport("zigimg", dep.module("zigimg"));
    if (gap_buffer_dep) |dep| tests.root_module.addImport("gap_buffer", dep.module("gap_buffer"));
    if (znvim_dep) |dep| tests.root_module.addImport("znvim", dep.module("znvim"));
    tests.root_module.addImport("build_options", options_mod);

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
