const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zig_deque = b.dependency("zig-deque", .{});

    const lib = b.addStaticLibrary(.{
        .name = "zig_gc",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.root_module.addImport("zig-deque", zig_deque.module("zig-deque"));

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zig_gc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_unit_tests.linkLibC();
    lib_unit_tests.root_module.addImport("zig-deque", zig_deque.module("zig-deque"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    setupBenchmarks(b, target, optimize, zig_deque);

    const check = b.step("check", "Check if it compiles");
    check.dependOn(&lib_unit_tests.step);
}

fn setupBenchmarks(b: *std.Build, target: anytype, optimize: anytype, zig_deque: anytype) void {
    const bench_step = b.step("bench", "Build benchmarks");
    const benchmark_names = [_][]const u8{"tree"};
    const zbench = b.dependency("zbench", .{});
    const zig_gc_mod = b.addModule("zig_gc", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    zig_gc_mod.addImport("zig-deque", zig_deque.module("zig-deque"));
    for (benchmark_names) |name| {
        const bench = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("bench/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        bench.linkLibC();
        bench.root_module.addImport("zig_gc", zig_gc_mod);
        bench.root_module.addImport("zbench", zbench.module("zbench"));
        const install_bench = b.addInstallArtifact(bench, .{});
        bench_step.dependOn(&bench.step);
        bench_step.dependOn(&install_bench.step);
    }
}
