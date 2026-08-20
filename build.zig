const std = @import("std");

/// The package version, single-sourced from build.zig.zon.
const version_string = blk: {
    const zon = @embedFile("build.zig.zon");
    const marker = ".version = \"";
    const start = (std.mem.indexOf(u8, zon, marker) orelse
        @compileError("no version in build.zig.zon")) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, zon, start, '"') orelse
        @compileError("unterminated version in build.zig.zon");
    break :blk zon[start..end];
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend for compile steps") orelse true;
    const external_uucode = b.option(bool, "external_uucode", "Use an externally provided uucode module instead of the built-in dependency") orelse false;
    const root_source_file = b.path("src/main.zig");

    // Dependencies
    const zigimg_dep = b.dependency("zigimg", .{
        .optimize = optimize,
        .target = target,
    });
    const uucode_mod = if (!external_uucode) blk: {
        const uucode_dep = b.lazyDependency("uucode", .{
            .target = target,
            .optimize = optimize,
            .fields = @as([]const []const u8, &.{
                "east_asian_width",
                "grapheme_break",
                "general_category",
                "is_emoji_presentation",
            }),
        }) orelse break :blk null;
        break :blk uucode_dep.module("uucode");
    } else null;

    // Module
    const vaxis_mod = b.addModule("vaxis", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    vaxis_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    if (uucode_mod) |mod| {
        vaxis_mod.addImport("uucode", mod);
    } else {
        // External uucode mode: consumer wires up their own uucode module on
        // the vaxis module. Skip examples, bench, tests, and docs steps since
        // they all depend on uucode being available here.
        return;
    }

    // Exposes the terminal input parser over a C ABI (see include/vaxis.h),
    const c_api_options = b.addOptions();
    c_api_options.addOption([]const u8, "version", version_string);
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "build_options", .module = c_api_options.createModule() },
        },
    });
    // For the @cImport-based layout test in src/c_api.zig
    c_api_mod.addIncludePath(b.path("include"));

    // Compile the C API once as PIC, then use the resulting object for both
    // library formats. Building two libraries directly from c_api_mod would
    // run Zig's frontend and code generator once per linkage.
    const c_api_object = b.addObject(.{
        .name = "vaxis-c-api",
        .root_module = c_api_mod,
        .use_llvm = use_llvm,
    });

    const static_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    static_mod.addObject(c_api_object);
    const static_lib = b.addLibrary(.{
        // the DLL import library is also named vaxis.lib on Windows
        .name = if (target.result.os.tag == .windows) "vaxis-static" else "vaxis",
        .linkage = .static,
        .root_module = static_mod,
        .use_llvm = use_llvm,
    });

    const shared_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shared_mod.addObject(c_api_object);
    const shared_lib = b.addLibrary(.{
        .name = "vaxis",
        .linkage = .dynamic,
        .root_module = shared_mod,
        .use_llvm = use_llvm,
        .version = std.SemanticVersion.parse(version_string) catch unreachable,
    });

    const install_static = b.addInstallArtifact(static_lib, .{});
    const install_shared = b.addInstallArtifact(shared_lib, .{});
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
    const lib_static_step = b.step("lib-static", "Build the static C library");
    lib_static_step.dependOn(&install_static.step);
    lib_static_step.dependOn(&install_headers.step);
    const lib_shared_step = b.step("lib-shared", "Build the shared C library");
    lib_shared_step.dependOn(&install_shared.step);
    lib_shared_step.dependOn(&install_headers.step);
    const lib_step = b.step("lib", "Build the C library (static and shared)");
    lib_step.dependOn(lib_static_step);
    lib_step.dependOn(lib_shared_step);

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
        text_view,
        list_view,
        vaxis,
        view,
        vt,
    };
    var examples: std.EnumMap(Example, *std.Build.Module) = .init(.{});
    inline for (std.meta.fields(Example)) |field| {
        const example: Example = @enumFromInt(field.value);
        examples.put(
            example,
            b.createModule(.{
                .root_source_file = b.path(
                    b.fmt("examples/{t}.zig", .{example}),
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "vaxis", .module = vaxis_mod },
                },
            }),
        );
    }
    const example_option = b.option(Example, "example", "Example to run (default: text_input)") orelse .text_input;
    const example_step = b.step("example", "Run example");
    const example = b.addExecutable(.{
        .name = b.fmt("example-{t}", .{example_option}),
        .root_module = examples.get(example_option) orelse unreachable,
        .use_llvm = use_llvm,
    });

    b.getInstallStep().dependOn(&example.step);

    const example_run = b.addRunArtifact(example);
    example_step.dependOn(&example_run.step);

    // Benchmarks
    const bench_step = b.step("bench", "Run benchmarks");
    const bench = b.addExecutable(.{
        .name = "bench",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| {
        bench_run.addArgs(args);
    }
    bench_step.dependOn(&bench_run.step);

    // Tests
    const tests_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
                .{ .name = "uucode", .module = uucode_mod.? },
            },
        }),
    });

    // Let's make sure that all of the examples compile and can run any tests
    // that they may have defined.
    var it = examples.iterator();
    while (it.next()) |v| {
        const e = b.addTest(.{
            .use_llvm = use_llvm,
            .root_module = v.value.*,
        });
        const r = b.addRunArtifact(e);
        tests_step.dependOn(&r.step);
    }

    const tests_run = b.addRunArtifact(tests);
    b.installArtifact(tests);
    tests_step.dependOn(&tests_run.step);

    // C API tests: Zig unit tests plus a C program linked against the
    // static library
    const c_api_tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = c_api_mod,
    });
    tests_step.dependOn(&b.addRunArtifact(c_api_tests).step);

    const c_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_test_mod.addCSourceFile(.{
        .file = b.path("examples/c/parse.c"),
        .flags = &.{ "-std=c99", "-pedantic-errors" },
    });
    c_test_mod.addIncludePath(b.path("include"));
    c_test_mod.linkLibrary(static_lib);
    const c_test = b.addExecutable(.{
        .name = "example-c-parse",
        .root_module = c_test_mod,
        .use_llvm = use_llvm,
    });
    tests_step.dependOn(&b.addRunArtifact(c_test).step);

    const c_runtime_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_runtime_mod.addCSourceFile(.{
        .file = b.path("examples/c/runtime.c"),
        .flags = &.{ "-std=c99", "-pedantic-errors" },
    });
    c_runtime_mod.addIncludePath(b.path("include"));
    c_runtime_mod.linkLibrary(static_lib);
    const c_runtime_test = b.addExecutable(.{
        .name = "example-c-runtime",
        .root_module = c_runtime_mod,
        .use_llvm = use_llvm,
    });
    tests_step.dependOn(&b.addRunArtifact(c_runtime_test).step);

    // Docs
    const docs_step = b.step("docs", "Build the vaxis library docs");
    const docs_obj = b.addObject(.{
        .name = "vaxis",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
        }),
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
