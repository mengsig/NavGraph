const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("NavGraph", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    // Fingerprint NavGraph's own source so the on-disk parse cache
    // (`.navgraph/cache`) is invalidated whenever the indexer/parser logic
    // changes — even when the serialized layout is byte-identical. Without this,
    // a cache written by an older binary can silently survive a logic fix and
    // keep serving stale (buggy) results. The key is content-addressed: the same
    // source always yields the same key, so switching git branches reuses each
    // branch's matching cache instead of thrashing it.
    const build_opts = b.addOptions();
    build_opts.addOption(u64, "cache_key", srcFingerprint(b));
    // Release/packaging systems may supply a VCS revision without making the
    // build graph invoke git (which would be non-hermetic and fail in source
    // archives). The source fingerprint remains authoritative when omitted.
    build_opts.addOption([]const u8, "revision", b.option([]const u8, "revision", "source revision embedded in capability metadata") orelse "");
    const build_opts_mod = build_opts.createModule();
    mod.addImport("build_options", build_opts_mod);

    const exe = b.addExecutable(.{
        .name = "navgraph",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "NavGraph" is the name you will use in your source code to
                // import this module (e.g. `@import("NavGraph")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "NavGraph", .module = mod },
                .{ .name = "build_options", .module = build_opts_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setCwd(b.path("."));

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setCwd(b.path("."));

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Real executable/corpus contracts live outside the white-box test roots.
    // Named steps remain independently runnable, and the main `test` gate also
    // depends on both so CI cannot accidentally exercise only white-box roots.
    const contract_cmd = b.addSystemCommand(&.{"sh"});
    contract_cmd.addFileArg(b.path("tests/agent-contract.sh"));
    contract_cmd.addArtifactArg(exe);
    contract_cmd.addDirectoryArg(b.path("."));
    contract_cmd.setCwd(b.path("."));
    const contract_step = b.step("contract", "Run black-box agent and polyglot corpus contracts");
    contract_step.dependOn(&contract_cmd.step);

    // The shell contract covers real corpus behavior. This generated companion
    // consumes the executable's own capability JSON and synthesizes invalid and
    // valid argv, catching descriptor/parser drift without duplicating flags.
    const manifest_contract_exe = b.addExecutable(.{
        .name = "manifest-contract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/manifest-contract.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const manifest_contract_cmd = b.addRunArtifact(manifest_contract_exe);
    manifest_contract_cmd.addArtifactArg(exe);
    manifest_contract_cmd.addDirectoryArg(b.path("."));
    manifest_contract_cmd.setCwd(b.path("."));
    contract_step.dependOn(&manifest_contract_cmd.step);

    const efficiency_cmd = b.addSystemCommand(&.{"sh"});
    efficiency_cmd.addFileArg(b.path("tests/efficiency-contract.sh"));
    efficiency_cmd.addArtifactArg(exe);
    efficiency_cmd.addDirectoryArg(b.path("."));
    efficiency_cmd.setCwd(b.path("."));
    const efficiency_step = b.step("efficiency", "Check deterministic agent-context compression budgets");
    efficiency_step.dependOn(&efficiency_cmd.step);

    // Accuracy benchmark: scores the indexer against the hand-verified golden
    // corpora in tests/golden/. It links the graph engine directly (the JSON
    // command surfaces drop kinds, so scoring through them would exempt the
    // constructs the corpora exist to stress).
    const accuracy_bench_exe = b.addExecutable(.{
        .name = "accuracy-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/accuracy-bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "NavGraph", .module = mod }},
        }),
    });
    const accuracy_cmd = b.addSystemCommand(&.{"sh"});
    accuracy_cmd.addFileArg(b.path("tests/accuracy.sh"));
    accuracy_cmd.addArtifactArg(accuracy_bench_exe);
    accuracy_cmd.addDirectoryArg(b.path("."));
    accuracy_cmd.setCwd(b.path("."));
    if (b.args) |args| accuracy_cmd.addArgs(args);
    const accuracy_step = b.step("bench", "Score the indexer against the golden accuracy corpora");
    accuracy_step.dependOn(&accuracy_cmd.step);
    test_step.dependOn(&contract_cmd.step);
    test_step.dependOn(&manifest_contract_cmd.step);
    test_step.dependOn(&efficiency_cmd.step);
    test_step.dependOn(&accuracy_cmd.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// A content hash of every `src/**.zig` file, used as the parse-cache version
/// key. Any edit to the indexer/parser changes this value, so a cache produced
/// by a different build is transparently ignored (a safe rebuild). Best-effort:
/// if the tree can't be read for any reason we return 0 — the cache still works,
/// it just falls back to the coarser layout-magic guard.
fn srcFingerprint(b: *std.Build) u64 {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    // Collect paths first and sort them, so the hash is independent of the
    // filesystem's directory-iteration order (which is not stable across runs).
    var walker = dir.walk(b.allocator) catch return 0;
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch return 0) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        paths.append(b.allocator, b.allocator.dupe(u8, entry.path) catch return 0) catch return 0;
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);

    var hasher = std.hash.Wyhash.init(0);
    for (paths.items) |p| {
        hasher.update(p); // path renames must also change the key
        const data = dir.readFileAlloc(io, p, b.allocator, .unlimited) catch return 0;
        hasher.update(data);
    }
    return hasher.final();
}
