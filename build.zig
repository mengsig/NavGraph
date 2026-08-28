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
    const grammars = selectGrammars(b);
    const build_opts = b.addOptions();
    build_opts.addOption(u64, "cache_key", buildKey(b, grammars));
    // Release/packaging systems may supply a VCS revision without making the
    // build graph invoke git (which would be non-hermetic and fail in source
    // archives). The source fingerprint remains authoritative when omitted.
    build_opts.addOption([]const u8, "revision", b.option([]const u8, "revision", "source revision embedded in capability metadata") orelse "");
    build_opts.addOption(bool, "ts_python", grammars.python);
    build_opts.addOption(bool, "ts_typescript", grammars.typescript);
    build_opts.addOption(bool, "ts_tsx", grammars.tsx);
    const build_opts_mod = build_opts.createModule();
    mod.addImport("build_options", build_opts_mod);
    linkTreeSitter(b, mod, target, grammars);

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

    // The backend differ runs both parser backends over the fixture trees and
    // asserts what tree-sitter is allowed to change (see tests/backend-differ.zig).
    // It needs the NavGraph module, so it is its own test root rather than a
    // white-box test inside src/.
    const differ_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/backend-differ.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "NavGraph", .module = mod },
                .{ .name = "build_options", .module = build_opts_mod },
            },
        }),
    });
    const run_differ_tests = b.addRunArtifact(differ_tests);
    run_differ_tests.setCwd(b.path("."));
    const differ_step = b.step("differ", "Diff the heuristic and tree-sitter backends over the fixture trees");
    differ_step.dependOn(&run_differ_tests.step);
    test_step.dependOn(&run_differ_tests.step);

    const efficiency_cmd = b.addSystemCommand(&.{"sh"});
    efficiency_cmd.addFileArg(b.path("tests/efficiency-contract.sh"));
    efficiency_cmd.addArtifactArg(exe);
    efficiency_cmd.addDirectoryArg(b.path("."));
    efficiency_cmd.setCwd(b.path("."));
    const efficiency_step = b.step("efficiency", "Check deterministic agent-context compression budgets");
    efficiency_step.dependOn(&efficiency_cmd.step);
    test_step.dependOn(&contract_cmd.step);
    test_step.dependOn(&manifest_contract_cmd.step);
    test_step.dependOn(&efficiency_cmd.step);

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

/// Content hash of the source plus the build variant, used as the parse-cache
/// version key and as the published source fingerprint. Any edit to the
/// indexer/parser changes it, so a cache produced by a different build is
/// transparently ignored (a safe rebuild). Best-effort: if the tree can't be
/// read for any reason we return 0 — the cache still works, it just falls back
/// to the coarser layout-magic guard.
fn buildKey(b: *std.Build, grammars: Grammars) u64 {
    var hasher = std.hash.Wyhash.init(0);
    // `src/queries/**.scm` is @embedFile'd into the tree-sitter backend, so a
    // query edit changes parse output without touching any .zig file — it must
    // be keyed too, or a stale cache masks the change.
    hashTree(b, &hasher, "src", ".zig") catch return 0;
    hashTree(b, &hasher, "src", ".scm") catch return 0;
    // The linked grammar set changes what the SAME source extracts, so it is
    // part of the build's identity: without it a `-Dtree-sitter=none` binary
    // accepts (and serves) a grammar-linked binary's cache.
    hasher.update(&[_]u8{
        @intFromBool(grammars.python),
        @intFromBool(grammars.typescript),
        @intFromBool(grammars.tsx),
    });
    return hasher.final();
}

/// Fold every `<root>/**` file ending in `ext` (path + contents) into `hasher`.
/// A missing root contributes nothing, so an optional tree is not an error.
fn hashTree(b: *std.Build, hasher: *std.hash.Wyhash, root: []const u8, ext: []const u8) !void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    // Collect paths first and sort them, so the hash is independent of the
    // filesystem's directory-iteration order (which is not stable across runs).
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ext)) continue;
        try paths.append(b.allocator, try b.allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);

    for (paths.items) |p| {
        hasher.update(root);
        hasher.update(p); // path renames must also change the key
        hasher.update(try dir.readFileAlloc(io, p, b.allocator, .unlimited));
    }
}

/// Which tree-sitter grammars this build links in. Each costs binary size
/// (python +0.45 MB, typescript +1.4 MB, tsx +1.4 MB stripped), so the set is a
/// build-time choice rather than "everything, always".
const Grammars = struct {
    python: bool,
    typescript: bool,
    tsx: bool,

    fn any(self: Grammars) bool {
        return self.python or self.typescript or self.tsx;
    }
};

/// Parse `-Dtree-sitter=<all|none|comma list>`. Default is every grammar the
/// repo ships. An unrecognised name is a hard build error rather than a silently
/// dropped grammar — a typo must not quietly ship a heuristic-only binary.
fn selectGrammars(b: *std.Build) Grammars {
    const raw = b.option(
        []const u8,
        "tree-sitter",
        "tree-sitter grammars to link: all | none | comma list of python,typescript,tsx (default: all)",
    ) orelse "all";
    if (std.mem.eql(u8, raw, "all")) return .{ .python = true, .typescript = true, .tsx = true };
    if (std.mem.eql(u8, raw, "none")) return .{ .python = false, .typescript = false, .tsx = false };

    var sel = Grammars{ .python = false, .typescript = false, .tsx = false };
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |name_raw| {
        const name = std.mem.trim(u8, name_raw, " ");
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "python")) {
            sel.python = true;
        } else if (std.mem.eql(u8, name, "typescript")) {
            sel.typescript = true;
        } else if (std.mem.eql(u8, name, "tsx")) {
            sel.tsx = true;
        } else {
            std.debug.panic(
                "-Dtree-sitter: unknown grammar '{s}' (expected all, none, or a comma list of python,typescript,tsx)",
                .{name},
            );
        }
    }
    return sel;
}

/// Compile the tree-sitter runtime and the selected grammars into one static
/// library and link it into `mod`. Always ReleaseSmall and stripped regardless
/// of the project's optimize mode: the generated parser tables are the dominant
/// binary-size cost and nothing in them benefits from ReleaseFast.
fn linkTreeSitter(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    grammars: Grammars,
) void {
    if (!grammars.any()) return;
    const runtime = b.lazyDependency("tree_sitter", .{}) orelse return;

    const lib = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .link_libc = true,
        }),
    });
    // gnu11, not c11: lib/src/unicode.h and parser.c use le16toh/be16toh and
    // fdopen unguarded, which strict ISO hides.
    lib.root_module.addCSourceFile(.{ .file = runtime.path("vendor/tree-sitter/lib/src/lib.c"), .flags = &.{"-std=gnu11"} });
    lib.root_module.addIncludePath(runtime.path("vendor/tree-sitter/lib/include"));
    lib.root_module.addIncludePath(runtime.path("vendor/tree-sitter/lib/src"));

    if (grammars.python) {
        if (b.lazyDependency("tree_sitter_python", .{})) |dep|
            addGrammar(b, lib, dep, "src", true);
    }
    if (grammars.typescript or grammars.tsx) {
        if (b.lazyDependency("tree_sitter_typescript", .{})) |dep| {
            if (grammars.typescript) addGrammar(b, lib, dep, "typescript/src", true);
            if (grammars.tsx) addGrammar(b, lib, dep, "tsx/src", true);
        }
    }
    mod.linkLibrary(lib);
}

/// Add one generated grammar (`<sub>/parser.c`, plus `scanner.c` when the
/// grammar has an external scanner) to `lib`.
fn addGrammar(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    dep: *std.Build.Dependency,
    sub: []const u8,
    has_scanner: bool,
) void {
    const flags = &.{"-std=gnu11"};
    lib.root_module.addCSourceFile(.{ .file = dep.path(b.pathJoin(&.{ sub, "parser.c" })), .flags = flags });
    if (has_scanner)
        lib.root_module.addCSourceFile(.{ .file = dep.path(b.pathJoin(&.{ sub, "scanner.c" })), .flags = flags });
    // Generated parsers include "tree_sitter/parser.h" from their own src dir.
    lib.root_module.addIncludePath(dep.path(sub));
}
