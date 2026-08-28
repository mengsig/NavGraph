//! NavGraph CLI entry point: parse args, build the index, dispatch the query.

const std = @import("std");
const model = @import("model.zig");
const cli = @import("cli.zig");
const index_mod = @import("index.zig");
const backends = @import("backends.zig");
const query = @import("query.zig");
const workflow = @import("workflow.zig");
const hierarchy = @import("hierarchy.zig");
const exceptions = @import("exceptions.zig");
const taint = @import("taint.zig");
const history_mod = @import("history.zig");
const json_out = @import("json_out.zig");
const viz = @import("viz.zig");
const capabilities = @import("capabilities.zig");
const agent_api = @import("agent_api.zig");
const workspace_path = @import("workspace_path.zig");
const lsp = @import("lsp.zig");
const gitutil = @import("gitutil.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    var stderr_buffer: [4 * 1024]u8 = undefined;
    var stderr_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_file.interface;

    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];
    // Bare `navgraph` (no args) prints help and succeeds.
    if (args.len == 0) {
        cli.usage(out) catch std.process.exit(141);
        out.flush() catch std.process.exit(141);
        return;
    }
    const parsed = cli.parse(args) catch |err| {
        // A malformed invocation is a usage error: one precise line on stderr
        // (never the full help dump — ~75 lines an agent pays for per typo) and
        // exit non-zero so callers (agents, scripts) can detect the failure.
        const detail = cli.diag();
        if (detail.len != 0) {
            try err_out.print("navgraph: {s}\n", .{detail});
        } else {
            try err_out.print("navgraph: {s}\n", .{cli.reason(err)});
        }
        try err_out.writeAll("run `navgraph help` for usage\n");
        try err_out.flush();
        std.process.exit(2);
    };
    // A global-class flag the command does not use is accepted so a client's
    // standard argv keeps working, but never silently: name it on stderr.
    {
        var it = parsed.ignored_options.iterator();
        while (it.next()) |option| {
            try err_out.print("navgraph: option '{s}' does not apply to {s}; ignored\n", .{
                cli.registry.optionDescriptor(option).name,
                @tagName(parsed.command),
            });
        }
        try err_out.flush();
    }
    if (parsed.command == .help) {
        if (parsed.arg.len == 0) {
            cli.usage(out) catch std.process.exit(141);
        } else {
            _ = cli.usageCommand(out, parsed.arg) catch std.process.exit(141);
        }
        out.flush() catch std.process.exit(141);
        return;
    }
    if (parsed.command == .capabilities) {
        capabilities.writeManifest(out) catch std.process.exit(141);
        out.writeByte('\n') catch std.process.exit(141);
        out.flush() catch std.process.exit(141);
        return;
    }
    if (parsed.command == .read) {
        const found = query.readLinesStandalone(out, io, gpa, parsed.root, parsed.arg, parsed.options) catch |err| switch (err) {
            error.WriteFailed => std.process.exit(141),
            else => return err,
        };
        out.flush() catch std.process.exit(141);
        if (!found) std.process.exit(1);
        return;
    }

    // The editor server owns stdout (it is the protocol channel) and builds its
    // own resident index, so it runs before the one-shot index build below.
    if (parsed.command == .lsp) return runLspServer(gpa, io, err_out, parsed);

    if (parsed.command == .serve) {
        var authority = RootAuthority.open(gpa, io, parsed.root) catch |err| {
            try out.print("navgraph: failed to bind server root '{s}': {s}\n", .{ parsed.root, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        var authority_owned = true;
        errdefer if (authority_owned) authority.deinit();
        // Session-lifetime, not per-build: `reload` re-indexes the whole tree
        // and must not recompile every grammar to do it.
        var registry = backends.Registry.init(gpa);
        defer registry.deinit();
        const parsing = backends.Parsing{ .choice = parsed.backend, .registry = &registry };
        var idx = index_mod.buildOpenDir(
            gpa,
            io,
            authority.dir,
            parsed.root,
            authority.single_file,
            authority.single_file_target,
            parsed.use_cache,
            parsing,
        ) catch |err| {
            try out.print("navgraph: failed to index '{s}': {s}\n", .{ parsed.root, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        defer idx.deinit();
        var session = try ServerSession.initBound(gpa, io, &idx, parsed.root, parsed.use_cache, parsing, authority);
        authority_owned = false;
        defer session.deinit();
        try serve(out, &session);
        try out.flush();
        return;
    }

    // The three 1.1 mirrors need a `Session`, not the `*Index` the generic
    // one-shot dispatch below builds — see `lsp.mirrors`'s doc comment.
    if (parsed.command == .hunks or parsed.command == .context or parsed.command == .where) {
        const found = runMirrorCommand(gpa, io, arena, out, parsed) catch |err| switch (err) {
            error.WriteFailed => std.process.exit(141),
            else => return err,
        };
        out.flush() catch std.process.exit(141);
        if (!found) std.process.exit(1);
        return;
    }
    var idx = index_mod.build(gpa, io, parsed.root, parsed.use_cache, parsed.backend) catch |err| {
        try out.print("navgraph: failed to index '{s}': {s}\n", .{ parsed.root, @errorName(err) });
        try out.flush();
        // The diagnostic is the product contract. Returning the error from
        // `main` adds an internal Zig stack trace that is noisy and unactionable
        // for an agent.
        std.process.exit(1);
    };
    defer idx.deinit();

    const found = dispatchHardBudget(out, io, &idx, parsed) catch |err| switch (err) {
        // Downstream closed the pipe (`navgraph … | head`). That's a normal way
        // to consume a Unix tool, not an internal error: exit quietly with the
        // conventional SIGPIPE status instead of spraying `error.WriteFailed`.
        error.WriteFailed => std.process.exit(141),
        else => return err,
    };
    // flush's only error is WriteFailed — same broken-pipe treatment.
    out.flush() catch std.process.exit(141);
    // grep convention: 0 = found results, 1 = query ran fine but found nothing
    // (the "(no …)" note), so scripts/agents can branch on $? instead of
    // re-parsing output. Usage errors exit 2, indexing failures propagate.
    if (!found) std.process.exit(1);
}

/// Run `navgraph lsp` and exit with the code the LSP session ended on.
fn runLspServer(gpa: std.mem.Allocator, io: std.Io, err_out: *std.Io.Writer, parsed: cli.Parsed) !void {
    const level = lsp.handlers.LogLevel.parse(parsed.log_level) orelse {
        try err_out.print("navgraph: unknown --log-level '{s}' (expected error|info|debug)\n", .{parsed.log_level});
        try err_out.flush();
        std.process.exit(2);
    };
    const code = try lsp.run(gpa, io, .{
        // An explicit `--root` pins the index root; otherwise the client's
        // workspace root from `initialize` decides (falling back to cwd).
        .root = if (parsed.root_given) parsed.root else "",
        .log_path = parsed.log_path,
        .log_level = level,
        .backend = parsed.backend,
    });
    if (code != 0) std.process.exit(code);
}

/// `navgraph hunks/context/where`: build a one-shot `Session` (see
/// `lsp.mirrors`'s doc comment for why), run the requested mirror into an
/// in-memory buffer, then render it — the buffer's bytes verbatim for `-j`,
/// or `writeMirrorText`'s reformatting of the same JSON for text (the CLI's
/// default). A malformed/unresolved input is reported the way `diff`/`read`
/// already report theirs: a format-aware message on stdout
/// (`query.emitError`) and `found = false` (the caller maps that to exit 1,
/// same as every other one-shot command); only a real internal failure
/// propagates as an error. An index-build failure is reported the same way
/// `index_mod.build`'s own failure is on every other command (message + exit
/// 1 right here) — that is a distinct, earlier failure class than "the query
/// ran but found nothing".
fn runMirrorCommand(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, out: *std.Io.Writer, parsed: cli.Parsed) !bool {
    var session = lsp.session.Session.init(gpa, io, parsed.root, .{ .watch = false }, parsed.backend, parsed.use_cache) catch |err| {
        try out.print("navgraph: failed to index '{s}': {s}\n", .{ parsed.root, @errorName(err) });
        out.flush() catch std.process.exit(141);
        std.process.exit(1);
    };
    defer session.deinit();
    const ctx = lsp.mirrors.ctxOf(&session);

    var aw: std.Io.Writer.Allocating = .init(arena);
    var detail: ?[]const u8 = null;
    const mirror_err: ?anyerror = switch (parsed.command) {
        .hunks => blk: {
            lsp.mirrors.hunks(&aw.writer, arena, ctx, parsed.arg, &detail) catch |err| break :blk err;
            break :blk null;
        },
        .context => blk: {
            const budget = if (parsed.options.context_budget != 0) parsed.options.context_budget else 2000;
            const include = if (parsed.used_options.contains(.include))
                lsp.mirrors.parseIncludeCsv(parsed.options.include) catch |err| {
                    detail = "unknown --include value (expected callers, callees, types, tests, body)";
                    break :blk err;
                }
            else
                lsp.queries.ContextInclude{};
            lsp.mirrors.context(&aw.writer, arena, ctx, parsed.arg, budget, include) catch |err| {
                if (err == error.SymbolNotFound)
                    detail = std.fmt.allocPrint(arena, "no definition named '{s}'", .{parsed.arg}) catch null;
                break :blk err;
            };
            break :blk null;
        },
        .where => blk: {
            const loc = lsp.mirrors.parseFileLine(parsed.arg) orelse {
                detail = std.fmt.allocPrint(arena, "malformed location '{s}' (expected file:line, 1-based)", .{parsed.arg}) catch null;
                break :blk error.InvalidParams;
            };
            lsp.mirrors.where(&aw.writer, arena, ctx, loc.path, loc.line) catch |err| break :blk err;
            break :blk null;
        },
        else => unreachable,
    };

    if (mirror_err) |err| {
        // Downstream closed the pipe mid-query (in-memory buffer, so this can
        // only be an arena OOM) — a real failure, not "nothing found".
        if (err == error.WriteFailed) return err;
        const message = detail orelse lsp.mirrors.errorMessage(err);
        try query.emitError(out, parsed.options.format, message);
        return false;
    }

    switch (parsed.options.format) {
        .json, .jsonl => {
            try out.writeAll(aw.written());
            try out.writeByte('\n');
        },
        .text => try writeMirrorText(out, arena, parsed.command, aw.written()),
    }
    return true;
}

/// Re-render one mirror's JSON (`runMirrorCommand`'s buffer — always the
/// exact `lsp.queries.write*` output) as text. This is presentation only: the
/// query itself already ran once, above: text mode never re-derives the
/// answer, only reformats it, so the two output formats can never disagree.
fn writeMirrorText(out: *std.Io.Writer, arena: std.mem.Allocator, command: cli.Command, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    switch (command) {
        .where => try writeWhereText(out, root),
        .context => try writeContextText(out, root),
        .hunks => try writeHunksText(out, root),
        else => unreachable,
    }
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

/// One line for a `Symbol` object: `kind qualified — file:line`.
fn writeSymbolLine(out: *std.Io.Writer, indent: []const u8, sym: std.json.Value) !void {
    const o = sym.object;
    try out.print("{s}{s} {s} — {s}:{d}\n", .{ indent, jsonStr(o, "kind"), jsonStr(o, "qualified"), jsonStr(o, "file"), jsonInt(o, "line") });
}

fn writeSymbolArray(out: *std.Io.Writer, label: []const u8, arr: std.json.Value) !void {
    const items = arr.array.items;
    try out.print("{s} ({d}):\n", .{ label, items.len });
    if (items.len == 0) {
        try out.writeAll("  (none)\n");
        return;
    }
    for (items) |sym| try writeSymbolLine(out, "  ", sym);
}

fn writeWhereText(out: *std.Io.Writer, root: std.json.ObjectMap) !void {
    const enclosing = root.get("enclosing") orelse .null;
    if (enclosing == .null) {
        try out.print("(no enclosing symbol in {s})\n", .{jsonStr(root, "file")});
        return;
    }
    try out.writeAll("enclosing: ");
    try writeSymbolLine(out, "", enclosing);
    const chain = root.get("breadcrumbs").?.array.items;
    try out.writeAll("breadcrumbs: ");
    for (chain, 0..) |sym, i| {
        if (i != 0) try out.writeAll(" > ");
        try out.writeAll(jsonStr(sym.object, "qualified"));
    }
    try out.writeByte('\n');
}

fn writeContextText(out: *std.Io.Writer, root: std.json.ObjectMap) !void {
    const sym = root.get("symbol").?.object;
    try out.print("{s} {s} — {s}:{d}\n{s}\n", .{
        jsonStr(sym, "kind"), jsonStr(sym, "qualified"), jsonStr(sym, "file"), jsonInt(sym, "line"), jsonStr(sym, "sig"),
    });
    const doc = jsonStr(sym, "doc");
    if (doc.len != 0) try out.print("\n{s}\n", .{doc});
    const def = root.get("definition").?.object;
    const text = jsonStr(def, "text");
    if (text.len != 0) try out.print("\ndefinition:\n{s}\n", .{text});
    try out.writeByte('\n');
    try writeSymbolArray(out, "callers", root.get("callers").?);
    try writeSymbolArray(out, "callees", root.get("callees").?);
    try writeSymbolArray(out, "types", root.get("types").?);
    try writeSymbolArray(out, "tests", root.get("tests").?);
    const truncated = root.get("truncated").?.bool;
    try out.print("truncated: {}  tokensEstimate: {d}\n", .{ truncated, jsonInt(root, "tokensEstimate") });
}

fn writeHunksText(out: *std.Io.Writer, root: std.json.ObjectMap) !void {
    const hunks_arr = root.get("hunks").?.array.items;
    try out.print("changeId: {s}\nhunks ({d}):\n", .{ jsonStr(root, "changeId"), hunks_arr.len });
    for (hunks_arr) |h| {
        const ho = h.object;
        const range = ho.get("range").?.object;
        const start_line = range.get("start").?.object.get("line").?.integer + 1;
        const end_line = range.get("end").?.object.get("line").?.integer + 1;
        const roots = ho.get("roots").?.array.items;
        // A hunk's own JSON carries a `file://` `uri` (no separate relative
        // path); a root's `file` field is the repo-relative one the rest of
        // this renderer already uses, so prefer it when the hunk has a root.
        const path = if (roots.len != 0) jsonStr(roots[0].object, "file") else jsonStr(ho, "uri");
        try out.print("  {s} lines {d}-{d}:\n", .{ path, start_line, end_line });
        for (roots) |sym| try writeSymbolLine(out, "    ", sym);
    }
    try writeSymbolArray(out, "roots", root.get("roots").?);
    const summary = root.get("summary").?.object;
    try out.print(
        "blast: {d} symbols, {d} files, {d} tests, maxDepth {d}, truncated {}\n",
        .{ jsonInt(summary, "symbols"), jsonInt(summary, "files"), jsonInt(summary, "tests"), jsonInt(summary, "maxDepth"), summary.get("truncated").?.bool },
    );
}

/// Say on stderr how many graph nodes `-l` withheld.
fn noteGraphTruncation(io: std.Io, truncation: viz.Truncation, limit: u32) !void {
    var buf: [128]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try file.interface.print("navgraph: graph truncated to {d} of {d} nodes (-l {d})\n", .{
        truncation.shown, truncation.total, limit,
    });
    try file.interface.flush();
}

/// Run the parsed command; true when at least one real result row was printed
/// (notes, suggestions, and empty JSON arrays don't count).
fn dispatch(out: *std.Io.Writer, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) !bool {
    return dispatchWithAuthority(out, io, idx, parsed, null);
}

fn dispatchWithAuthority(
    out: *std.Io.Writer,
    io: std.Io,
    idx: *index_mod.Index,
    parsed: cli.Parsed,
    authority: ?*const RootAuthority,
) !bool {
    return switch (parsed.command) {
        .outline => try query.outline(out, idx, parsed.arg, parsed.options),
        .files => try query.listFiles(out, idx, parsed.arg, parsed.options),
        .status => if (authority) |root| bound: {
            var canonical_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical = try root.canonicalPath(&canonical_buf);
            break :bound try query.statusInRoot(
                out,
                io,
                idx,
                root.dir,
                canonical,
                root.single_file_target,
                parsed.arg,
                parsed.options,
            );
        } else try query.status(out, io, idx, parsed.arg, parsed.options),
        .read => if (authority) |root| bound: {
            var canonical_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical = try root.canonicalPath(&canonical_buf);
            break :bound try query.readLinesInRoot(
                out,
                io,
                idx,
                root.dir,
                canonical,
                root.single_file,
                root.single_file_target,
                parsed.arg,
                parsed.options,
            );
        } else try query.readLines(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .strings => try query.strings(out, idx, parsed.arg, parsed.options),
        .def => try query.showDef(out, idx, parsed.arg, parsed.options),
        .docs => try workflow.docs(out, idx, parsed.arg, parsed.options),
        .calls => try query.walk(out, idx, parsed.arg, false, parsed.options),
        .callers => try query.walk(out, idx, parsed.arg, true, parsed.options),
        .search => try query.search(out, idx, parsed.arg, parsed.options),
        .collisions => try query.collisions(out, idx, parsed.arg, parsed.options),
        .routes => try query.listRoutes(out, idx, parsed.arg, parsed.options),
        .events => try query.events(out, idx, parsed.arg, parsed.options),
        .conforms => try query.conforms(out, idx, parsed.arg, parsed.options),
        .hierarchy => try hierarchy.run(out, idx, parsed.arg, parsed.options),
        .raises => try exceptions.raises(out, idx, parsed.arg, parsed.options),
        .catches => try exceptions.catches(out, idx, parsed.arg, parsed.options),
        .neighbors => try query.neighbors(out, idx, parsed.arg, parsed.options),
        .unused => try query.unused(out, idx, parsed.arg, parsed.options),
        .imports => try query.listImports(out, idx, parsed.arg, parsed.options),
        .importers => try query.listImporters(out, idx, parsed.arg, parsed.options),
        .path => try query.shortestPath(out, idx, parsed.arg, parsed.arg2, parsed.options),
        .flow => try query.flow(out, idx, parsed.arg, parsed.options),
        .taint => try taint.run(out, idx, parsed.arg, parsed.options),
        .reaches => try workflow.reaches(out, idx, parsed.arg, parsed.options),
        .affected => if (authority) |root|
            try workflow.affectedAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try workflow.affected(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .hot => try query.hot(out, idx, parsed.arg, parsed.options),
        .diff => if (authority) |root|
            try query.diffAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try query.diff(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .history => if (authority) |root|
            try history_mod.historyAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try history_mod.history(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .blame => if (authority) |root|
            try history_mod.blameAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try history_mod.blame(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .churn => if (authority) |root|
            try history_mod.churnAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try history_mod.churn(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .todos => try workflow.todos(out, idx, parsed.arg, parsed.options),
        .edits => try workflow.edits(out, idx, parsed.arg, parsed.options),
        .rename => try workflow.rename(out, io, idx, parsed.root, parsed.arg, parsed.arg2, parsed.options),
        .coverage => try query.coverage(out, idx, parsed.arg, parsed.options),
        .graph => blk: {
            const truncation = try viz.graph(out, idx, parsed.arg, parsed.options);
            // The JSON model carries `truncated`/`nodes_total`; the HTML page has
            // nowhere to put it and stdout must stay a valid page, so say it on
            // stderr instead of passing a capped subgraph off as the graph.
            if (truncation.any() and parsed.options.format != .json)
                try noteGraphTruncation(io, truncation, parsed.options.limit);
            break :blk true; // graph always emits a page/model
        },
        // `.hunks`/`.context`/`.where` are intercepted in `main()`, before
        // `dispatchWithAuthority` is ever reached (`runMirrorCommand`): they
        // need a `Session`, not the `*Index` this function dispatches over.
        .capabilities, .serve, .lsp, .help, .hunks, .context, .where => unreachable,
    };
}

const CapturedDispatch = struct {
    bytes: []u8,
    found: bool,
};

/// `--budget` is an exact serialized stdout contract. Individual query domains
/// still use it to rank/prune likely-useful rows, then this final boundary
/// measures the real rendering (signatures, source, JSON escaping, metadata and
/// all) and compacts/re-renders until the complete value fits.
fn dispatchHardBudget(out: *std.Io.Writer, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) !bool {
    return dispatchHardBudgetWithAuthority(out, io, idx, parsed, null);
}

fn dispatchHardBudgetWithAuthority(
    out: *std.Io.Writer,
    io: std.Io,
    idx: *index_mod.Index,
    parsed: cli.Parsed,
    authority: ?*const RootAuthority,
) !bool {
    if (parsed.options.budget == 0 or parsed.command == .read) return dispatchWithAuthority(out, io, idx, parsed, authority);
    const hard_limit = parsed.options.budget;

    const initial = try captureDispatch(idx.gpa, io, idx, parsed, authority);
    defer idx.gpa.free(initial.bytes);
    if (initial.bytes.len <= hard_limit) {
        try out.writeAll(initial.bytes);
        return initial.found;
    }
    const found = initial.found;

    var compact = parsed;
    compact.options.budget = 0;
    compact.options.summary = true;
    compact.options.verbosity = .names;
    // Raw patches cannot be semantically compacted by lowering a result count;
    // fall back to the changed-symbol summary before resorting to a metadata-only
    // hard-budget response.
    if (compact.command == .diff) compact.options.exact_source = false;
    var cap = compact.options.limit;
    if (compact.options.max_nodes != 0) cap = @min(cap, compact.options.max_nodes);
    cap = @min(cap, @max(@as(u32, 1), hard_limit / 96));

    compact.options.limit_set = true;
    while (true) {
        compact.options.limit = cap;
        compact.options.max_nodes = cap;
        const rendered = try captureDispatch(idx.gpa, io, idx, compact, authority);
        defer idx.gpa.free(rendered.bytes);
        const annotated = try annotateHardBudget(idx.gpa, rendered.bytes, parsed.options.format, hard_limit, initial.bytes.len);
        defer idx.gpa.free(annotated);
        if (annotated.len <= hard_limit) {
            try out.writeAll(annotated);
            return found;
        }
        if (cap == 1) break;
        cap = @max(@as(u32, 1), cap / 2);
    }

    const minimal = try hardBudgetOnly(idx.gpa, parsed.options.format, hard_limit);
    defer idx.gpa.free(minimal);
    std.debug.assert(minimal.len <= hard_limit);
    try out.writeAll(minimal);
    return found;
}

fn captureDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    idx: *index_mod.Index,
    parsed: cli.Parsed,
    authority: ?*const RootAuthority,
) !CapturedDispatch {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const found = try dispatchWithAuthority(&aw.writer, io, idx, parsed, authority);
    return .{ .bytes = try allocator.dupe(u8, aw.written()), .found = found };
}

fn annotateHardBudget(
    allocator: std.mem.Allocator,
    raw: []const u8,
    format: query.OutputFormat,
    budget: u32,
    original_bytes: usize,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const w = &aw.writer;
    switch (format) {
        .text => {
            try w.writeAll(raw);
            if (raw.len != 0 and raw[raw.len - 1] != '\n') try w.writeByte('\n');
            try w.print("… hard byte budget truncated/compacted output (budget={}, original_bytes={})\n", .{ budget, original_bytes });
        },
        .json => {
            const trimmed = std.mem.trimEnd(u8, raw, " \t\r\n");
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                try w.writeAll(trimmed[0 .. trimmed.len - 1]);
                if (std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n").len != 0) try w.writeByte(',');
                try w.print("{{\"truncated\":true,\"reason\":\"hard_byte_budget\",\"budget\":{},\"original_bytes\":{}}}]\n", .{ budget, original_bytes });
            } else if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
                try w.writeAll(trimmed[0 .. trimmed.len - 1]);
                if (std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n").len != 0) try w.writeByte(',');
                try w.print("\"hard_budget\":{{\"truncated\":true,\"budget\":{},\"original_bytes\":{}}}}}\n", .{ budget, original_bytes });
            } else {
                return hardBudgetOnly(allocator, format, budget);
            }
        },
        .jsonl => {
            try w.writeAll(raw);
            if (raw.len != 0 and raw[raw.len - 1] != '\n') try w.writeByte('\n');
            try w.print("{{\"kind\":\"budget\",\"truncated\":true,\"budget\":{},\"original_bytes\":{}}}\n", .{ budget, original_bytes });
        },
    }
    return aw.toOwnedSlice();
}

fn hardBudgetOnly(allocator: std.mem.Allocator, format: query.OutputFormat, budget: u32) ![]u8 {
    var buf: [96]u8 = undefined;
    const rendered = switch (format) {
        .text => std.fmt.bufPrint(&buf, "… output truncated (--budget {})\n", .{budget}) catch "",
        .json, .jsonl => std.fmt.bufPrint(&buf, "{{\"truncated\":true,\"reason\":\"hard_byte_budget\",\"budget\":{}}}\n", .{budget}) catch "{}\n",
    };
    // CLI validation keeps budgets >=64, enough for the complete diagnostic.
    // Retain a defensive slice for programmatic Options constructed in tests.
    return allocator.dupe(u8, rendered[0..@min(rendered.len, budget)]);
}

const RootAuthority = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    single_file: ?[]u8,
    single_file_target: ?[]u8,

    fn open(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !RootAuthority {
        std.debug.assert(root.len > 0);
        var single_file: ?[]u8 = null;
        errdefer if (single_file) |file| gpa.free(file);
        var single_file_target: ?[]u8 = null;
        errdefer if (single_file_target) |target| gpa.free(target);
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| opened: {
            if (err != error.NotDir) return err;
            single_file = try gpa.dupe(u8, std.fs.path.basename(root));
            const parent = std.fs.path.dirname(root) orelse ".";
            break :opened try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
        };
        errdefer dir.close(io);
        var canonical_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canonical_len = try dir.realPath(io, &canonical_buf);
        if (single_file) |path| {
            var file = try workspace_path.openFileKnownRoot(dir, io, canonical_buf[0..canonical_len], path);
            defer file.close(io);
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const target = try workspace_path.openedRelativePath(file, io, canonical_buf[0..canonical_len], &target_buf);
            single_file_target = try gpa.dupe(u8, target);
        }
        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .single_file = single_file,
            .single_file_target = single_file_target,
        };
    }

    fn canonicalPath(self: *const RootAuthority, buffer: []u8) ![]const u8 {
        const len = try self.dir.realPath(self.io, buffer);
        return buffer[0..len];
    }

    fn deinit(self: *RootAuthority) void {
        self.dir.close(self.io);
        if (self.single_file) |file| self.gpa.free(file);
        if (self.single_file_target) |target| self.gpa.free(target);
        self.* = undefined;
    }
};

const ServerSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *index_mod.Index,
    root: []u8,
    authority: RootAuthority,
    use_cache: bool,
    /// Parse context this session was started with — the backend and the
    /// grammars compiled for it. Reloads reuse both.
    parsing: backends.Parsing,
    snapshot_id: u64,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        idx: *index_mod.Index,
        root: []const u8,
        use_cache: bool,
        parsing: backends.Parsing,
    ) !ServerSession {
        var authority = try RootAuthority.open(gpa, io, root);
        errdefer authority.deinit();
        return initBound(gpa, io, idx, root, use_cache, parsing, authority);
    }

    fn initBound(
        gpa: std.mem.Allocator,
        io: std.Io,
        idx: *index_mod.Index,
        root: []const u8,
        use_cache: bool,
        parsing: backends.Parsing,
        authority_value: RootAuthority,
    ) !ServerSession {
        std.debug.assert(root.len > 0);
        std.debug.assert(idx.gpa.ptr == gpa.ptr);
        return .{
            .gpa = gpa,
            .io = io,
            .idx = idx,
            .root = try gpa.dupe(u8, root),
            // Ownership transfers only after every fallible field above has
            // initialized. The caller retains and cleans authority_value when
            // this function returns an error.
            .authority = authority_value,
            .use_cache = use_cache,
            .parsing = parsing,
            .snapshot_id = agent_api.snapshotFingerprint(idx),
        };
    }

    fn deinit(self: *ServerSession) void {
        self.authority.deinit();
        self.gpa.free(self.root);
        self.* = undefined;
    }

    fn reload(self: *ServerSession, use_cache: bool) !void {
        std.debug.assert(self.root.len > 0);
        std.debug.assert(self.idx.gpa.ptr == self.gpa.ptr);
        var fresh = try index_mod.buildOpenDir(
            self.gpa,
            self.io,
            self.authority.dir,
            self.root,
            self.authority.single_file,
            self.authority.single_file_target,
            use_cache,
            self.parsing,
        );
        const fresh_snapshot_id = agent_api.snapshotFingerprint(&fresh);
        const old = self.idx.*;
        self.idx.* = fresh;
        self.snapshot_id = fresh_snapshot_id;
        fresh = old;
        fresh.deinit();
    }
};

fn serve(out: *std.Io.Writer, session: *ServerSession) !void {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(session.idx.graph.files.len > 0 or session.idx.graph.symbols.len == 0);
    var input_buffer: [64 * 1024]u8 = undefined;
    var stdin_file: std.Io.File.Reader = .initStreaming(.stdin(), session.io, &input_buffer);
    const input = &stdin_file.interface;
    while (true) {
        const maybe = input.takeDelimiter('\n') catch |err| switch (err) {
            // A request line that fills the whole input buffer would otherwise
            // crash the long-lived server. Drain it (through the newline) to
            // resync, report a parse error, and keep serving. If it cannot be
            // drained (EOF / read failure), stop cleanly instead of looping.
            error.StreamTooLong => {
                const drained = input.discardDelimiterInclusive('\n');
                try rpcError(out, null, -32700, "request line exceeds input buffer");
                try out.flush();
                _ = drained catch return;
                continue;
            },
            error.ReadFailed => return err,
        };
        const raw = maybe orelse break;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const keep_going = try handleServerRequest(out, session, line);
        try out.flush();
        if (!keep_going) return;
    }
}

fn handleServerRequest(out: *std.Io.Writer, session: *ServerSession, line: []const u8) !bool {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(line.len > 0);
    var parsed = std.json.parseFromSlice(std.json.Value, session.gpa, line, .{}) catch {
        try rpcError(out, null, -32700, "invalid JSON");
        return true;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try rpcError(out, null, -32600, "request must be an object");
        return true;
    }
    const obj = parsed.value.object;
    const id = obj.get("id");
    const version = obj.get("jsonrpc") orelse {
        try rpcError(out, id, -32600, "missing jsonrpc version");
        return true;
    };
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) {
        try rpcError(out, id, -32600, "jsonrpc must be 2.0");
        return true;
    }
    const method_value = obj.get("method") orelse {
        try rpcError(out, id, -32600, "missing method");
        return true;
    };
    if (method_value != .string) {
        try rpcError(out, id, -32600, "method must be a string");
        return true;
    }
    const method = method_value.string;
    if (std.mem.eql(u8, method, "workspace/reload")) return rpcReload(out, session, id, obj.get("params"));
    if (std.mem.startsWith(u8, method, "notifications/")) return true;
    if (id == null) return true;
    if (std.mem.eql(u8, method, "initialize")) return rpcInitialize(out, id);
    if (std.mem.eql(u8, method, "navgraph/capabilities")) return rpcCapabilities(out, id);
    if (std.mem.eql(u8, method, "tools/list")) return rpcTools(out, id);
    if (std.mem.eql(u8, method, "tools/call")) return rpcToolCall(out, session, id, obj.get("params"));
    if (std.mem.eql(u8, method, "ping")) {
        try rpcResultPrefix(out, id);
        try out.writeAll("{} }\n");
        return true;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        try rpcResultPrefix(out, id);
        try out.writeAll("null}\n");
        return false;
    }
    try rpcError(out, id, -32601, "unknown method");
    return true;
}

fn rpcInitialize(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"protocolVersion\":");
    try json_out.writeString(out, capabilities.mcp_protocol_version);
    try out.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":false},\"experimental\":{\"navgraph\":{\"capabilitySchema\":");
    try json_out.writeString(out, capabilities.capability_schema);
    try out.print(",\"capabilitySchemaVersion\":{},\"agentProtocolVersion\":", .{capabilities.capability_schema_version});
    try json_out.writeString(out, capabilities.agent_protocol_version);
    try out.print(",\"schemaHash\":\"wyhash64:{x:0>16}\"", .{capabilities.schemaFingerprint()});
    try out.writeAll(",\"capabilitiesMethod\":\"navgraph/capabilities\",\"capabilitiesTool\":\"navgraph.capabilities\",\"queryTool\":");
    try json_out.writeString(out, agent_api.tool_name);
    try out.writeAll(",\"querySchema\":");
    try json_out.writeString(out, agent_api.query_schema);
    try out.writeAll(",\"resultSchema\":");
    try json_out.writeString(out, agent_api.result_schema);
    try out.print(",\"agentSchemaHash\":\"wyhash64:{x:0>16}\"", .{agent_api.inputSchemaFingerprint()});
    try out.writeAll(",\"buildId\":\"");
    try capabilities.writeBuildId(out);
    try out.writeAll("\"}}},\"serverInfo\":{\"name\":\"navgraph\",\"version\":\"");
    try capabilities.writeBuildVersion(out);
    try out.writeAll("\"}}}\n");
    return true;
}

fn rpcCapabilities(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try capabilities.writeManifest(out);
    try out.writeAll("}\n");
    return true;
}

fn rpcTools(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"tools\":[");
    try out.writeAll("{\"name\":\"");
    try out.writeAll(agent_api.tool_name);
    try out.writeAll("\",\"description\":\"Compact typed read-only API; no argv or mutation. map uses query/path; symbol views definition/docs/source; relations views callees/callers/neighbors/imports/importers/hierarchy/implementations/path/flow; source uses bounded lines; impact views edit_sites/affected_tests/changed_symbols; diagnostics views status/coverage. Protocol ");
    try out.writeAll(capabilities.agent_protocol_version);
    try out.writeAll("; build ");
    try capabilities.writeBuildId(out);
    try out.writeAll(". max_bytes hard-bounds structuredContent.\",\"inputSchema\":");
    try agent_api.writeInputSchema(out);
    try out.writeAll(",\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true}},");
    try out.writeAll("{\"name\":\"navgraph\",\"description\":\"Legacy read-only argv compatibility tool. Prefer navgraph.query. Mutating commands, including rename and rename --preview, are rejected.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"args\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"string\"}}},\"required\":[\"args\"],\"additionalProperties\":false},\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false}},");
    try out.writeAll("{\"name\":\"navgraph.capabilities\",\"description\":\"Return NavGraph's machine-readable protocol, build identity, language, command, option, output, access, and trust contract without rebuilding the index.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}},");
    try out.writeAll("{\"name\":\"navgraph.reload\",\"description\":\"Atomically rebuild and replace the server's in-memory index\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"noCache\":{\"type\":\"boolean\"}},\"additionalProperties\":false}},");
    // 1.1 mirrors of navgraph/impact, navgraph/context and navgraph/where
    // (docs/lsp.md "1.1"): each builds its own one-shot index per call rather
    // than sharing this server's resident one (src/lsp/mirrors.zig's doc
    // comment explains why), so a call here costs a fresh walk, unlike
    // navgraph.query above.
    try out.writeAll("{\"name\":\"navgraph.hunks\",\"description\":\"navgraph/impact mirror: the working change's hunks, blast radius and roots. Default ref is HEAD, like affected/diff.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"ref\":{\"type\":\"string\"}},\"additionalProperties\":false},\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true}},");
    try out.writeAll("{\"name\":\"navgraph.context\",\"description\":\"navgraph/context mirror: one symbol's definition, callers/callees/types/tests in a single call, trimmed to a token budget (default 2000; 0 also means default).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"budget\":{\"type\":\"integer\",\"minimum\":0},\"include\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"callers\",\"callees\",\"types\",\"tests\",\"body\"]}}},\"required\":[\"symbol\"],\"additionalProperties\":false},\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true}},");
    try out.writeAll("{\"name\":\"navgraph.where\",\"description\":\"navgraph/where mirror: the symbol enclosing a 1-based file:line, plus its breadcrumb chain.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\"},\"line\":{\"type\":\"integer\",\"minimum\":1}},\"required\":[\"file\",\"line\"],\"additionalProperties\":false},\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true}}]}}\n");
    return true;
}

fn rpcReload(
    out: *std.Io.Writer,
    session: *ServerSession,
    id: ?std.json.Value,
    params: ?std.json.Value,
) !bool {
    reloadFromValue(session, params) catch |err| {
        if (id) |_| try rpcError(out, id, reloadErrorCode(err), @errorName(err));
        return true;
    };
    if (id == null) return true;
    try rpcResultPrefix(out, id);
    try writeReloadMetadata(out, session);
    try out.writeAll("}\n");
    return true;
}

fn rpcReloadTool(
    out: *std.Io.Writer,
    session: *ServerSession,
    id: ?std.json.Value,
    arguments: std.json.Value,
) !bool {
    std.debug.assert(id != null);
    reloadFromValue(session, arguments) catch |err| {
        try rpcError(out, id, reloadErrorCode(err), @errorName(err));
        return true;
    };
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":\"index reloaded\"}],\"isError\":false,\"index\":");
    try writeReloadMetadata(out, session);
    try out.writeAll("}}\n");
    return true;
}

fn reloadFromValue(session: *ServerSession, value: ?std.json.Value) !void {
    var no_cache = false;
    if (value) |params| {
        if (params != .object) return error.InvalidReloadArguments;
        const field_count = params.object.count();
        const raw = params.object.get("noCache");
        if (field_count > @as(usize, @intFromBool(raw != null))) return error.InvalidReloadArguments;
        if (raw) |flag| {
            if (flag != .bool) return error.InvalidReloadArguments;
            no_cache = flag.bool;
        }
    }
    try session.reload(if (no_cache) false else session.use_cache);
}

fn reloadErrorCode(err: anyerror) i32 {
    return if (err == error.InvalidReloadArguments) -32602 else -32603;
}

fn writeReloadMetadata(out: *std.Io.Writer, session: *const ServerSession) !void {
    const snapshot = session.idx.cache_snapshot;
    try out.print("{{\"files\":{},\"symbols\":{},\"cache_hits\":{},\"cache_rewrite\":\"{s}\"}}", .{
        session.idx.graph.files.len, session.idx.graph.symbols.len, snapshot.hits, @tagName(snapshot.rewrite),
    });
}

fn rpcToolCall(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, params_value: ?std.json.Value) !bool {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(id != null);
    if (params_value == null or params_value.? != .object) {
        try rpcError(out, id, -32602, "tools/call requires params");
        return true;
    }
    const params = params_value.?.object;
    const name = params.get("name") orelse {
        try rpcError(out, id, -32602, "missing tool name");
        return true;
    };
    if (name != .string) {
        try rpcError(out, id, -32602, "tool name must be a string");
        return true;
    }
    const arguments = params.get("arguments") orelse {
        try rpcError(out, id, -32602, "missing arguments");
        return true;
    };
    if (arguments != .object) {
        try rpcError(out, id, -32602, "arguments must be an object");
        return true;
    }
    if (std.mem.eql(u8, name.string, "navgraph"))
        return runServerTool(out, session, id, arguments.object.get("args"));
    if (std.mem.eql(u8, name.string, agent_api.tool_name))
        return runAgentTool(out, session, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.capabilities"))
        return rpcCapabilitiesTool(out, session.gpa, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.reload"))
        return rpcReloadTool(out, session, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.hunks"))
        return rpcHunksTool(out, session, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.context"))
        return rpcContextTool(out, session, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.where"))
        return rpcWhereTool(out, session, id, arguments);
    try rpcError(out, id, -32602, "unknown tool");
    return true;
}

// ---------------------------------------------------------------------------
// navgraph.hunks / navgraph.context / navgraph.where: the 1.1 mirror tools.
// Each opens its own one-shot Session over `session.root` (lsp.mirrors' doc
// comment explains why this doesn't reuse `session.idx`) and runs the exact
// same lsp.mirrors call the CLI verb runs, so the query logic is one
// implementation shared by the LSP server, the CLI and this MCP surface.
// ---------------------------------------------------------------------------

/// Open a one-shot mirror session over `session.root`, or report an
/// index-build failure as a tool error (matching the CLI's equivalent
/// failure, but as a JSON-RPC error here since there is no stdout to print
/// a diagnostic to).
fn openMirrorSession(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value) !?lsp.session.Session {
    return lsp.session.Session.init(session.gpa, session.io, session.root, .{ .watch = false }, session.use_cache) catch |err| {
        var buf: [192]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "failed to index '{s}': {s}", .{ session.root, @errorName(err) }) catch "failed to index";
        try rpcError(out, id, -32603, message);
        return null;
    };
}

/// Write one mirror's structured result: `writeAgentResult`'s envelope shape
/// (a `structuredContent` object an MCP client reads directly, plus a
/// placeholder `content` message), reusing that convention rather than
/// inventing a second one for these three tools.
fn writeMirrorResult(out: *std.Io.Writer, id: ?std.json.Value, json: []const u8) !void {
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":\"NavGraph structured result\"}],\"structuredContent\":");
    try out.writeAll(json);
    try out.writeAll(",\"isError\":false}}\n");
}

fn rpcHunksTool(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, arguments: std.json.Value) !bool {
    std.debug.assert(id != null);
    var ref: []const u8 = "";
    for (arguments.object.keys(), arguments.object.values()) |key, value| {
        if (!std.mem.eql(u8, key, "ref")) {
            try rpcError(out, id, -32602, "unknown field for navgraph.hunks (expected: ref)");
            return true;
        }
        if (value != .string) {
            try rpcError(out, id, -32602, "ref must be a string");
            return true;
        }
        ref = value.string;
    }

    var mirror_session = (try openMirrorSession(out, session, id)) orelse return true;
    defer mirror_session.deinit();
    const ctx = lsp.mirrors.ctxOf(&mirror_session);

    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    var detail: ?[]const u8 = null;
    lsp.mirrors.hunks(&aw.writer, arena, ctx, ref, &detail) catch |err| {
        try rpcError(out, id, lsp.mirrors.errorCode(err), detail orelse lsp.mirrors.errorMessage(err));
        return true;
    };
    try writeMirrorResult(out, id, aw.written());
    return true;
}

fn rpcContextTool(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, arguments: std.json.Value) !bool {
    std.debug.assert(id != null);
    var symbol: ?[]const u8 = null;
    var budget: u32 = 2000;
    var include: lsp.queries.ContextInclude = .{};
    for (arguments.object.keys(), arguments.object.values()) |key, value| {
        if (std.mem.eql(u8, key, "symbol")) {
            if (value != .string or value.string.len == 0) {
                try rpcError(out, id, -32602, "symbol must be a non-empty string");
                return true;
            }
            symbol = value.string;
        } else if (std.mem.eql(u8, key, "budget")) {
            if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) {
                try rpcError(out, id, -32602, "budget must be a non-negative integer");
                return true;
            }
            // 0 is the wire contract's own "use the default" value, same as
            // an absent budget — not a special case to reject or zero out.
            if (value.integer != 0) budget = @intCast(value.integer);
        } else if (std.mem.eql(u8, key, "include")) {
            if (value != .array) {
                try rpcError(out, id, -32602, "include must be an array of strings");
                return true;
            }
            include = lsp.queries.ContextInclude.none;
            for (value.array.items) |item| {
                if (item != .string) {
                    try rpcError(out, id, -32602, "include items must be strings");
                    return true;
                }
                const s = item.string;
                if (std.mem.eql(u8, s, "callers")) {
                    include.callers = true;
                } else if (std.mem.eql(u8, s, "callees")) {
                    include.callees = true;
                } else if (std.mem.eql(u8, s, "types")) {
                    include.types = true;
                } else if (std.mem.eql(u8, s, "tests")) {
                    include.tests = true;
                } else if (std.mem.eql(u8, s, "body")) {
                    include.body = true;
                } else {
                    try rpcError(out, id, -32602, "include values must be one of: callers, callees, types, tests, body");
                    return true;
                }
            }
        } else {
            try rpcError(out, id, -32602, "unknown field for navgraph.context (expected: symbol, budget, include)");
            return true;
        }
    }
    const sym = symbol orelse {
        try rpcError(out, id, -32602, "symbol is required");
        return true;
    };

    var mirror_session = (try openMirrorSession(out, session, id)) orelse return true;
    defer mirror_session.deinit();
    const ctx = lsp.mirrors.ctxOf(&mirror_session);

    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    lsp.mirrors.context(&aw.writer, arena, ctx, sym, budget, include) catch |err| {
        const message = if (err == error.SymbolNotFound)
            std.fmt.allocPrint(arena, "no definition named '{s}'", .{sym}) catch lsp.mirrors.errorMessage(err)
        else
            lsp.mirrors.errorMessage(err);
        try rpcError(out, id, lsp.mirrors.errorCode(err), message);
        return true;
    };
    try writeMirrorResult(out, id, aw.written());
    return true;
}

fn rpcWhereTool(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, arguments: std.json.Value) !bool {
    std.debug.assert(id != null);
    var file: ?[]const u8 = null;
    var line: ?u32 = null;
    for (arguments.object.keys(), arguments.object.values()) |key, value| {
        if (std.mem.eql(u8, key, "file")) {
            if (value != .string or value.string.len == 0) {
                try rpcError(out, id, -32602, "file must be a non-empty string");
                return true;
            }
            file = value.string;
        } else if (std.mem.eql(u8, key, "line")) {
            if (value != .integer or value.integer < 1 or value.integer > std.math.maxInt(u32)) {
                try rpcError(out, id, -32602, "line must be a positive integer (1-based)");
                return true;
            }
            line = @intCast(value.integer);
        } else {
            try rpcError(out, id, -32602, "unknown field for navgraph.where (expected: file, line)");
            return true;
        }
    }
    const f = file orelse {
        try rpcError(out, id, -32602, "file is required");
        return true;
    };
    const l = line orelse {
        try rpcError(out, id, -32602, "line is required");
        return true;
    };

    var mirror_session = (try openMirrorSession(out, session, id)) orelse return true;
    defer mirror_session.deinit();
    const ctx = lsp.mirrors.ctxOf(&mirror_session);

    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    lsp.mirrors.where(&aw.writer, arena, ctx, f, l) catch |err| {
        try rpcError(out, id, lsp.mirrors.errorCode(err), lsp.mirrors.errorMessage(err));
        return true;
    };
    try writeMirrorResult(out, id, aw.written());
    return true;
}

fn rpcCapabilitiesTool(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    arguments: std.json.Value,
) !bool {
    std.debug.assert(id != null);
    if (arguments != .object or arguments.object.count() != 0) {
        try rpcError(out, id, -32602, "navgraph.capabilities takes no arguments");
        return true;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer allocating.deinit();
    try capabilities.writeManifest(&allocating.writer);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try json_out.writeString(out, allocating.written());
    try out.writeAll("}],\"isError\":false,\"schema\":");
    try json_out.writeString(out, capabilities.capability_schema);
    try out.writeAll("}}\n");
    return true;
}

fn runServerTool(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, args_value: ?std.json.Value) !bool {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(session.idx.graph.symbols.len <= std.math.maxInt(model.SymbolId));
    if (args_value == null or args_value.? != .array or args_value.?.array.items.len == 0) {
        try rpcError(out, id, -32602, "args must be a non-empty string array");
        return true;
    }
    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try arena.alloc([:0]const u8, args_value.?.array.items.len);
    for (args_value.?.array.items, 0..) |value, i| {
        if (value != .string) {
            try rpcError(out, id, -32602, "every arg must be a string");
            return true;
        }
        args[i] = try arena.dupeZ(u8, value.string);
    }
    var request = cli.parse(args) catch {
        try rpcError(out, id, -32602, if (cli.diag().len != 0) cli.diag() else "invalid navgraph arguments");
        return true;
    };
    if (request.command == .capabilities) return rpcCapabilities(out, id);
    const descriptor = cli.registry.descriptor(request.command);
    if (descriptor.access != .read_only) {
        try rpcError(out, id, -32602, "legacy navgraph MCP tool is read-only; mutating commands are prohibited");
        return true;
    }
    if (!descriptor.server_available or !std.mem.eql(u8, request.root, ".")) {
        try rpcError(out, id, -32602, "this command or -C is not allowed inside a server request");
        return true;
    }
    request.root = session.root;
    try dispatchServerResult(out, session, id, request);
    return true;
}

fn runAgentTool(
    out: *std.Io.Writer,
    session: *ServerSession,
    id: ?std.json.Value,
    arguments: std.json.Value,
) !bool {
    std.debug.assert(id != null);
    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var request = agent_api.decode(arena, arguments) catch |err| {
        try rpcError(out, id, -32602, agent_api.reason(err));
        return true;
    };
    const descriptor = cli.registry.descriptor(request.parsed.command);
    if (descriptor.access != .read_only or !descriptor.server_available) {
        try rpcError(out, id, -32602, "navgraph.query resolved to a prohibited command");
        return true;
    }
    request.parsed.root = session.root;

    if (try agent_api.ambiguityEnvelopeOwned(session.gpa, session.idx, session.snapshot_id, request)) |envelope| {
        defer session.gpa.free(envelope);
        std.debug.assert(envelope.len <= request.max_bytes);
        try writeAgentResult(out, id, envelope);
        return true;
    }

    var raw_buf: std.ArrayList(u8) = .empty;
    defer raw_buf.deinit(session.gpa);
    var raw_writer: std.Io.Writer.Allocating = .fromArrayList(session.gpa, &raw_buf);
    defer raw_writer.deinit();
    const found = dispatchWithAuthority(&raw_writer.writer, session.io, session.idx, request.parsed, &session.authority) catch |err| {
        try rpcError(out, id, -32603, @errorName(err));
        return true;
    };
    const envelope = agent_api.envelopeOwned(session.gpa, session.idx, session.snapshot_id, request, found, raw_writer.written()) catch |err| {
        try rpcError(out, id, -32603, @errorName(err));
        return true;
    };
    defer session.gpa.free(envelope);
    std.debug.assert(envelope.len <= request.max_bytes);
    try writeAgentResult(out, id, envelope);
    return true;
}

fn writeAgentResult(out: *std.Io.Writer, id: ?std.json.Value, envelope: []const u8) !void {
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":\"NavGraph structured result\"}],\"structuredContent\":");
    try out.writeAll(envelope);
    try out.writeAll(",\"isError\":false}}\n");
}

fn dispatchServerResult(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, request: cli.Parsed) !void {
    std.debug.assert(request.command != .serve and request.command != .help);
    std.debug.assert(request.root.len > 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(session.gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(session.gpa, &buf);
    defer aw.deinit();
    const found = dispatchHardBudgetWithAuthority(&aw.writer, session.io, session.idx, request, &session.authority) catch |err| {
        try rpcError(out, id, -32603, @errorName(err));
        return;
    };
    if (found and request.command == .rename and !request.options.preview) {
        session.reload(session.use_cache) catch |err| {
            var message_buf: [192]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buf, "rename was applied, but index reload failed: {s}", .{@errorName(err)}) catch
                "rename was applied, but index reload failed";
            try rpcError(out, id, -32603, message);
            return;
        };
    }
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try json_out.writeString(out, aw.written());
    try out.writeAll("}],\"isError\":false");
    try out.writeAll(",\"found\":");
    try out.print("{}", .{found});
    try out.writeAll("}}\n");
}

fn rpcResultPrefix(out: *std.Io.Writer, id: ?std.json.Value) !void {
    std.debug.assert(id != null);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id.?, .{}, out);
    try out.writeAll(",\"result\":");
}

fn rpcError(out: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    std.debug.assert(message.len > 0);
    std.debug.assert(code < 0);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| try std.json.Stringify.value(value, .{}, out) else try out.writeAll("null");
    try out.print(",\"error\":{{\"code\":{},\"message\":", .{code});
    try json_out.writeString(out, message);
    try out.writeAll("}}\n");
}

// ---------------------------------------------------------------------------
// End-to-end dispatch() tests: parse (or hand-build) a cli.Parsed for each
// Command, build a real index from a tmpDir, run dispatch() into an Allocating
// buffer, and assert the rendered output matches the verb. Also verifies that
// cli.parse of a full argv round-trips into the right Command + options that
// dispatch then acts on.
// ---------------------------------------------------------------------------

/// Write the shared two-file sample project into `dir`. `app.zig` imports
/// `util.zig`; the call chain is run → mid → leaf (in-file) plus run →
/// util.helper → inner (cross-file). `orphan` is dead. `greeting` holds a
/// string literal for the `strings` verb.
fn writeSampleProject(io: std.Io, dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "app.zig", .data =
        \\const util = @import("util.zig");
        \\
        \\pub const greeting = "hello /api/health world";
        \\
        \\/// Run the sample workflow.
        \\pub fn run() void {
        \\    mid();
        \\    util.helper();
        \\}
        \\
        \\fn mid() void {
        \\    // TODO remove this wrapper after migration
        \\    leaf();
        \\}
        \\
        \\fn leaf() void {}
        \\
        \\fn orphan() void {}
    });
    try dir.writeFile(io, .{ .sub_path = "util.zig", .data =
        \\pub fn helper() void {
        \\    inner();
        \\}
        \\
        \\fn inner() void {}
    });
}

const SampleFixture = struct {
    tmp: std.testing.TmpDir,
    idx: index_mod.Index,
    registry: backends.Registry,

    /// Borrowed by any session the test starts, so it must outlive it — which
    /// it does: the fixture is the test frame's, torn down last.
    fn parsing(self: *SampleFixture) backends.Parsing {
        return .{ .choice = .auto, .registry = &self.registry };
    }

    fn deinit(self: *SampleFixture) void {
        self.registry.deinit();
        self.idx.deinit();
        self.tmp.cleanup();
    }
};

/// Build an index over a fresh copy of the sample project. Caller must
/// `defer fx.deinit()`.
fn sampleFixture(io: std.Io) !SampleFixture {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try writeSampleProject(io, tmp.dir);
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const idx = try index_mod.build(std.testing.allocator, io, root, false, .auto);
    return .{ .tmp = tmp, .idx = idx, .registry = backends.Registry.init(std.testing.allocator) };
}

fn ambiguousFixture(io: std.Io) !SampleFixture {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub const Alpha = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
        \\pub const Beta = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub const Gamma = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
        \\pub const Delta = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const idx = try index_mod.build(std.testing.allocator, io, root, false, .auto);
    return .{ .tmp = tmp, .idx = idx, .registry = backends.Registry.init(std.testing.allocator) };
}

/// Run dispatch() for `parsed` and return the rendered output (caller frees).
fn dispatchOwned(alloc: std.mem.Allocator, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &buf);
    defer aw.deinit();
    _ = try dispatch(&aw.writer, io, idx, parsed);
    return alloc.dupe(u8, aw.written());
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "dispatch outline lists the files and their symbols" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .outline });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "util.zig"));
    try std.testing.expect(has(out, "run"));
    try std.testing.expect(has(out, "mid"));
    try std.testing.expect(has(out, "helper"));
}

test "dispatch outline honors the path filter argument" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Filter to util.zig only: app.zig's private `mid` must not appear.
    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .outline, .arg = "util.zig" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "util.zig"));
    try std.testing.expect(has(out, "helper"));
    try std.testing.expect(!has(out, "app.zig"));
    try std.testing.expect(!has(out, "mid"));
}

test "dispatch files lists every indexed file" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .files });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "util.zig"));
}

test "dispatch def shows a definition signature" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .def, .arg = "run" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "run"));
    try std.testing.expect(has(out, "fn"));
    try std.testing.expect(has(out, "app.zig"));
}

test "dispatch def and search resolve glob patterns" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // `def` with a prefix glob lists every match (issue #3's `def Ba*` shape).
    const defs = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .def, .arg = "m*" });
    defer std.testing.allocator.free(defs);
    try std.testing.expect(has(defs, "mid"));
    try std.testing.expect(!has(defs, "leaf"));

    // `search` with a glob anchors on the whole name: `r*n` hits `run` only.
    const found = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .search, .arg = "r*n" });
    defer std.testing.allocator.free(found);
    try std.testing.expect(has(found, "run"));
    try std.testing.expect(!has(found, "orphan")); // substring would hit it; glob must not
}

test "index honors .navgraphignore: prune a source dir, re-include a built-in skip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".navgraphignore", .data = "junk/\n!node_modules/\n" });
    try tmp.dir.createDir(io, "junk", .default_dir);
    try tmp.dir.createDir(io, "node_modules", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "def real():\n    pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "junk/j.py", .data = "def scratch():\n    pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/v.py", .data = "def vendored():\n    pass\n" });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(std.testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    var saw_app = false;
    var saw_vendored = false;
    for (idx.graph.files) |f| {
        try std.testing.expect(!std.mem.startsWith(u8, f.path, "junk/")); // pruned
        if (std.mem.eql(u8, f.path, "app.py")) saw_app = true;
        if (std.mem.eql(u8, f.path, "node_modules/v.py")) saw_vendored = true;
    }
    try std.testing.expect(saw_app);
    try std.testing.expect(saw_vendored); // `!node_modules/` overrode the built-in skip
}

test "dispatch def on an unknown name reports not found without crashing" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .def, .arg = "no_such_symbol_xyz" });
    defer std.testing.allocator.free(out);

    // A miss must still produce output (a note) and never the symbol name.
    try std.testing.expect(out.len > 0);
    try std.testing.expect(has(out, "no_such_symbol_xyz"));
}

test "dispatch calls walks callees of a function" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .calls, .arg = "run" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "run"));
    try std.testing.expect(has(out, "mid")); // run → mid (in-file callee)
}

test "dispatch callers walks incoming edges of a function" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .callers, .arg = "leaf" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "leaf"));
    try std.testing.expect(has(out, "mid")); // mid → leaf, so mid is a caller
}

test "dispatch search finds symbols by name" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .search, .arg = "helper" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "helper"));
    try std.testing.expect(has(out, "util.zig"));
}

test "dispatch neighbors shows both callees and callers" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .neighbors, .arg = "mid" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "mid"));
    try std.testing.expect(has(out, "leaf")); // callee
    try std.testing.expect(has(out, "run")); // caller
}

test "dispatch unused flags an uncalled private function" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .unused });
    defer std.testing.allocator.free(out);

    // orphan is private, uncalled, and named nowhere → dead code.
    try std.testing.expect(has(out, "orphan"));
}

test "dispatch imports lists a file's local import edges" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .imports });
    defer std.testing.allocator.free(out);

    // app.zig imports util.zig.
    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "util.zig"));
}

test "dispatch importers lists reverse dependencies of a file" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .importers, .arg = "util.zig" });
    defer std.testing.allocator.free(out);

    // util.zig is imported by app.zig.
    try std.testing.expect(has(out, "util.zig"));
    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "imported by"));
}

test "dispatch path finds a call path and reports its absence" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // run → mid → leaf exists.
    const found = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .path, .arg = "run", .arg2 = "leaf" });
    defer std.testing.allocator.free(found);
    try std.testing.expect(has(found, "run"));
    try std.testing.expect(has(found, "leaf"));
    try std.testing.expect(!has(found, "no call path"));

    // No reverse path leaf → run.
    const none = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .path, .arg = "leaf", .arg2 = "run" });
    defer std.testing.allocator.free(none);
    try std.testing.expect(has(none, "no call path"));
}

test "dispatch hot ranks the load-bearing symbols" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .hot });
    defer std.testing.allocator.free(out);

    try std.testing.expect(out.len > 0);
    // mid is central: fan-in from run, fan-out to leaf.
    try std.testing.expect(has(out, "mid"));
}

test "dispatch read prints numbered source of an indexed file" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .read, .arg = "app.zig" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "pub fn run"));
    // Numbered lines use a tab separator.
    try std.testing.expect(has(out, "\t"));
}

test "dispatch read honors an explicit line range" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Line 3 of app.zig is the `greeting` const.
    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .read, .arg = "app.zig:3-3" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "greeting"));
    // The run function is on later lines and must be excluded by the range.
    try std.testing.expect(!has(out, "pub fn run"));
}

test "dispatch strings searches inside string literals" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .strings, .arg = "/api/health" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "/api/health"));
    try std.testing.expect(has(out, "app.zig"));
}

test "dispatch routes reports the empty case for a project with no routes" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .routes });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "no routes"));
}

test "dispatch events reports the empty case for a project with no dispatch" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .events });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "event"));
}

test "dispatch diff handles an unrunnable git root gracefully" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Point the diff at a nonexistent root so git cannot run; dispatch must
    // still return normally (the error is caught and reported, not propagated).
    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .diff,
        .root = "/nonexistent-navgraph-root-xyz-123",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "git diff"));
}

test "dispatch honors the json output format and emits well-formed JSON" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .calls,
        .arg = "run",
        .options = .{ .depth = 2, .format = .json },
    });
    defer std.testing.allocator.free(out);

    // Parse it to prove it is valid JSON, then assert on its shape.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(has(out, "\"name\":\"run\""));
}

test "dispatch honors the verbosity option (names hides signatures)" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // -v names lists bare names; the parameter/return signature `() void` must
    // not be rendered.
    const names = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .outline,
        .options = .{ .verbosity = .names },
    });
    defer std.testing.allocator.free(names);
    try std.testing.expect(has(names, "run"));

    // -v sig (default) includes the `fn ... void` signature text.
    const sig = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .outline,
        .options = .{ .verbosity = .sig },
    });
    defer std.testing.allocator.free(sig);
    try std.testing.expect(has(sig, "void"));
    // The names view is strictly shorter than the signature view.
    try std.testing.expect(names.len < sig.len);
}

test "cli.parse then dispatch round-trips a full argv through the pipeline" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Full argv (program name already stripped, as main.zig does).
    const parsed = try cli.parse(&.{ "search", "helper" });
    try std.testing.expectEqual(cli.Command.search, parsed.command);
    try std.testing.expectEqualStrings("helper", parsed.arg);

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, parsed);
    defer std.testing.allocator.free(out);
    try std.testing.expect(has(out, "helper"));
    try std.testing.expect(has(out, "util.zig"));
}

test "cli.parse maps command aliases and dispatch-relevant flags" {
    // `o` is an alias for outline; `-C` sets the root; `-j` selects JSON.
    const a = try cli.parse(&.{ "o", "src", "-C", "myroot", "-j" });
    try std.testing.expectEqual(cli.Command.outline, a.command);
    try std.testing.expectEqualStrings("src", a.arg);
    try std.testing.expectEqualStrings("myroot", a.root);
    try std.testing.expectEqual(query.OutputFormat.json, a.options.format);

    // `path` fills both positionals.
    const b = try cli.parse(&.{ "path", "alpha", "omega" });
    try std.testing.expectEqual(cli.Command.path, b.command);
    try std.testing.expectEqualStrings("alpha", b.arg);
    try std.testing.expectEqualStrings("omega", b.arg2);

    // `cat` is an alias for read.
    const c = try cli.parse(&.{ "cat", "x.zig" });
    try std.testing.expectEqual(cli.Command.read, c.command);
    try std.testing.expectEqualStrings("x.zig", c.arg);

    // `--no-cache` disables the on-disk cache flag dispatch/build reads.
    const d = try cli.parse(&.{ "outline", "--no-cache" });
    try std.testing.expect(!d.use_cache);
}

test "cli.parse rejects malformed invocations" {
    // Unknown command.
    try std.testing.expectError(error.Usage, cli.parse(&.{"frobnicate"}));
    // Missing required positional for a name verb.
    try std.testing.expectError(error.Usage, cli.parse(&.{"def"}));
    // path needs two positionals.
    try std.testing.expectError(error.Usage, cli.parse(&.{ "path", "onlyone" }));
    // Unknown flag.
    try std.testing.expectError(error.UnknownFlag, cli.parse(&.{ "outline", "--bogus" }));
}

// ---------------------------------------------------------------------------
// hunks/context/where: the 1.1 CLI mirrors (runMirrorCommand + cli.parse).
// Session-based, so they need their own fixture (a root path, not an
// already-built *Index — see lsp.mirrors's doc comment for why).
// ---------------------------------------------------------------------------

const MirrorFixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init(io: std.Io) !MirrorFixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try writeSampleProject(io, tmp.dir);
        const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *MirrorFixture) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

/// Run `runMirrorCommand` for `parsed` (`parsed.root` is overwritten with
/// `fx.root`) and return its rendered output plus `found`. Uses a real arena
/// for the `arena` parameter, same as `main()` does: `runMirrorCommand`
/// relies on bulk-free semantics there (an error `detail` is arena-allocated
/// and never individually freed), so a plain leak-tracked allocator would
/// flag it as a leak even though production never frees it either.
fn runMirrorOwned(io: std.Io, fx: MirrorFixture, parsed_in: cli.Parsed) !struct { text: []u8, found: bool } {
    const alloc = std.testing.allocator;
    var parsed = parsed_in;
    parsed.root = fx.root;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &buf);
    defer aw.deinit();
    const found = try runMirrorCommand(alloc, io, arena_state.allocator(), &aw.writer, parsed);
    return .{ .text = try alloc.dupe(u8, aw.written()), .found = found };
}

test "cli.parse maps hunks/context/where and their flags" {
    const h = try cli.parse(&.{ "hunks", "HEAD~1", "-j" });
    try std.testing.expectEqual(cli.Command.hunks, h.command);
    try std.testing.expectEqualStrings("HEAD~1", h.arg);
    try std.testing.expectEqual(query.OutputFormat.json, h.options.format);

    const c = try cli.parse(&.{ "context", "run", "--budget", "0", "--include", "callers,types" });
    try std.testing.expectEqual(cli.Command.context, c.command);
    try std.testing.expectEqualStrings("run", c.arg);
    try std.testing.expectEqual(@as(u32, 0), c.options.context_budget);
    try std.testing.expectEqualStrings("callers,types", c.options.include);
    try std.testing.expect(c.used_options.contains(.include));

    const w = try cli.parse(&.{ "where", "app.zig:7" });
    try std.testing.expectEqual(cli.Command.where, w.command);
    try std.testing.expectEqualStrings("app.zig:7", w.arg);

    // context's --budget is not the shared byte floor: 0 must not usage-error.
    _ = try cli.parse(&.{ "context", "run", "--budget", "0" });
    // ...but every other command's --budget still enforces the byte floor.
    try std.testing.expectError(error.BadValue, cli.parse(&.{ "calls", "run", "--budget", "0" }));
}

test "dispatch where names the enclosing symbol and breadcrumbs" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();

    const r = try runMirrorOwned(io, fx, .{ .command = .where, .arg = "app.zig:7", .options = .{ .format = .json } });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.found);
    try std.testing.expect(has(r.text, "run"));

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, r.text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("run", parsed.value.object.get("enclosing").?.object.get("name").?.string);
}

test "dispatch where off a malformed location reports the error and found=false, not a crash" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();

    const r = try runMirrorOwned(io, fx, .{ .command = .where, .arg = "app.zig" });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(!r.found);
    try std.testing.expect(has(r.text, "malformed location"));
}

test "dispatch context includes the callee chain and honors --include" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();

    var opts = query.Options{};
    opts.context_budget = 2000;
    opts.format = .json;
    const full = try runMirrorOwned(io, fx, .{ .command = .context, .arg = "run", .options = opts });
    defer std.testing.allocator.free(full.text);
    try std.testing.expect(full.found);
    try std.testing.expect(has(full.text, "mid"));

    var include_opts = query.Options{};
    include_opts.context_budget = 2000;
    include_opts.format = .json;
    var used = std.EnumSet(cli.registry.Option).initEmpty();
    used.insert(.include);
    const callers_only = try runMirrorOwned(io, fx, .{ .command = .context, .arg = "run", .options = include_opts, .used_options = used });
    defer std.testing.allocator.free(callers_only.text);
    try std.testing.expect(callers_only.found);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, callers_only.text, .{});
    defer parsed.deinit();
    // `include` given but empty (`""`) is a strict "nothing" allow-list.
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("callees").?.array.items.len);
}

test "dispatch context on an unknown symbol reports not found, not a crash" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();

    const r = try runMirrorOwned(io, fx, .{ .command = .context, .arg = "nope_xyz" });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(!r.found);
    try std.testing.expect(has(r.text, "no definition named"));
}

test "dispatch context budget 0 does not error, per navgraph/context's own contract" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();

    // context_budget defaults to 0, which runMirrorCommand maps to the wire
    // default (2000) rather than passing 0 straight through.
    const r = try runMirrorOwned(io, fx, .{ .command = .context, .arg = "run" });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.found);
}

test "dispatch hunks off a bad ref reports the error, not a crash" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();
    // A bare ref like "" would still resolve against *this worktree's own*
    // enclosing git repo (`.zig-cache/tmp/...` sits inside it) — an
    // unmistakably bad ref is what actually forces GitFailed deterministically,
    // reported the same way `diff`'s own "unrunnable git root" case is
    // (query.emitError, found=false), never a crash.
    const r = try runMirrorOwned(io, fx, .{ .command = .hunks, .arg = "not-a-real-ref-xyz" });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(!r.found);
    try std.testing.expect(has(r.text, "git diff"));
}

test "dispatch hunks reports the working change against HEAD, grouped by hunk" {
    const io = std.testing.io;
    var fx = try MirrorFixture.init(io);
    defer fx.deinit();
    const Git = struct {
        fn ok(allocator: std.mem.Allocator, test_io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
            const result = try gitutil.run(allocator, test_io, cwd, argv);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try std.testing.expect(result.term == .exited and result.term.exited == 0);
        }
    };
    try Git.ok(std.testing.allocator, io, fx.root, &.{ "git", "init", "--quiet" });
    try Git.ok(std.testing.allocator, io, fx.root, &.{ "git", "add", "--", "app.zig", "util.zig" });
    try Git.ok(std.testing.allocator, io, fx.root, &.{
        "git",     "-c",                   "user.name=NavGraph Test", "-c",                       "user.email=navgraph@example.invalid",
        "-c",      "commit.gpgsign=false", "-c",                      "core.hooksPath=/dev/null", "commit",
        "--quiet", "--no-verify",          "-m",                      "base",
    });
    // A single inserted line inside helper's own body: nothing else in the
    // file moves (in particular, no trailing-newline change on the file's
    // last line), so `git diff --unified=0` reports exactly one hunk.
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data = "pub fn helper() void {\n    inner();\n    _ = 1;\n}\n\nfn inner() void {}" });

    const r = try runMirrorOwned(io, fx, .{ .command = .hunks, .options = .{ .format = .json } });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.found);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, r.text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("hunks").?.array.items.len == 1);
    try std.testing.expectEqualStrings("helper", obj.get("roots").?.array.items[0].object.get("name").?.string);
}

test "phase 4 hierarchy exceptions and taint dispatch" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "depth.py", .data =
        \\class AppError(Exception): pass
        \\class OrderError(AppError): pass
        \\def fail(): raise OrderError("bad")
        \\def run(request):
        \\    try:
        \\        subprocess.run(request.json)
        \\    except OrderError:
        \\        return None
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const hierarchy_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .hierarchy, .arg = "AppError", .options = .{ .format = .json, .hierarchy_overrides = true } });
    defer testing.allocator.free(hierarchy_out);
    var hierarchy_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, hierarchy_out, .{});
    defer hierarchy_json.deinit();
    try testing.expect(has(hierarchy_out, "OrderError"));

    const raises_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .raises, .arg = "fail", .options = .{ .format = .json, .depth = 2 } });
    defer testing.allocator.free(raises_out);
    var raises_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, raises_out, .{});
    defer raises_json.deinit();
    try testing.expect(has(raises_out, "OrderError"));

    const catches_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .catches, .arg = "OrderError", .options = .{ .format = .json } });
    defer testing.allocator.free(catches_out);
    var catches_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, catches_out, .{});
    defer catches_json.deinit();
    try testing.expect(has(catches_out, "handler"));

    const taint_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .taint, .arg = "request.json", .options = .{ .flow_to = "subprocess.run", .format = .json } });
    defer testing.allocator.free(taint_out);
    var taint_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, taint_out, .{});
    defer taint_json.deinit();
    try testing.expect(has(taint_out, "\"status\":\"reachable\""));
}

test "phase 3 reachability, docs, todos, rename preview, and compaction dispatch" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const reach = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .reaches, .arg = "run" });
    defer testing.allocator.free(reach);
    try testing.expect(has(reach, "run"));
    try testing.expect(has(reach, "leaf"));

    const docs_out = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .docs, .arg = "run" });
    defer testing.allocator.free(docs_out);
    try testing.expect(has(docs_out, "sample workflow"));
    const todo_out = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .todos });
    defer testing.allocator.free(todo_out);
    try testing.expect(has(todo_out, "TODO remove this wrapper"));

    const preview = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .rename, .arg = "leaf", .arg2 = "finish", .options = .{ .preview = true } });
    defer testing.allocator.free(preview);
    try testing.expect(has(preview, "--- a/app.zig"));
    try testing.expect(has(preview, "+fn finish"));

    const bounded = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .calls, .arg = "run", .options = .{ .depth = 3, .max_nodes = 2, .summary = true } });
    defer testing.allocator.free(bounded);
    try testing.expect(has(bounded, "nodes shown"));
    try testing.expect(!has(bounded, "() void"));

    const bounded_neighbors = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .neighbors, .arg = "run", .options = .{ .max_nodes = 2, .summary = true } });
    defer testing.allocator.free(bounded_neighbors);
    try testing.expect(has(bounded_neighbors, "nodes shown"));
    try testing.expect(!has(bounded_neighbors, "() void"));

    // `-l/--limit` is the universal result contract, including tree walks.
    // It must cap nodes even when neither of the optional compaction flags is
    // present; agents rely on this before they know a graph's fan-out.
    const limited = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .calls, .arg = "run", .options = .{ .depth = 3, .limit = 1 } });
    defer testing.allocator.free(limited);
    try testing.expect(has(limited, "run"));
    try testing.expect(!has(limited, "mid"));
    try testing.expect(has(limited, "1 nodes shown"));

    const limited_json = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .neighbors, .arg = "run", .options = .{ .format = .json, .limit = 1 } });
    defer testing.allocator.free(limited_json);
    var parsed_limited = try std.json.parseFromSlice(std.json.Value, testing.allocator, limited_json, .{});
    defer parsed_limited.deinit();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, limited_json, "\"id\":"));
    try testing.expect(has(limited_json, "\"truncated\":true"));

    var hard_text_buf: std.ArrayList(u8) = .empty;
    defer hard_text_buf.deinit(testing.allocator);
    var hard_text_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &hard_text_buf);
    defer hard_text_writer.deinit();
    try testing.expect(try dispatchHardBudget(&hard_text_writer.writer, io, &fx.idx, .{
        .command = .calls,
        .arg = "run",
        .options = .{ .depth = 3, .verbosity = .full, .budget = 160 },
    }));
    try testing.expect(hard_text_writer.written().len <= 160);

    var hard_json_buf: std.ArrayList(u8) = .empty;
    defer hard_json_buf.deinit(testing.allocator);
    var hard_json_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &hard_json_buf);
    defer hard_json_writer.deinit();
    try testing.expect(try dispatchHardBudget(&hard_json_writer.writer, io, &fx.idx, .{
        .command = .neighbors,
        .arg = "run",
        .options = .{ .format = .json, .budget = 256 },
    }));
    try testing.expect(hard_json_writer.written().len <= 256);
    var hard_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, hard_json_writer.written(), .{});
    defer hard_json.deinit();
}

test "phase 3 JSONL pages are independently valid and expose a cursor" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    const out = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .search, .arg = "i", .options = .{ .format = .jsonl, .limit = 2 } });
    defer testing.allocator.free(out);

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        count += 1;
    }
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(has(out, "\"next\":\"v1:2\""));
}

test "serve handles MCP initialize and a tool call on the in-memory index" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false, fx.parsing());
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[\"search\",\"leaf\",\"-j\"]}}}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"unknown\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[\"search\",\"missing_symbol\",\"-j\"]}}}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"1.0\",\"id\":5,\"method\":\"ping\"}"));
    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        count += 1;
    }
    try testing.expectEqual(@as(u32, 5), count);
    try testing.expect(has(aw.written(), "\\\"name\\\":\\\"leaf\\\""));
    try testing.expect(has(aw.written(), "\"error\":{\"code\":-32601"));
    try testing.expect(has(aw.written(), "\"isError\":false,\"found\":false"));
    try testing.expect(has(aw.written(), "\"error\":{\"code\":-32600"));
}

test "MCP navgraph.where/context/hunks round-trip and reject hostile input" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false);
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    // app.zig line 7 is `mid();` inside `run`.
    try testing.expect(try handleServerRequest(&aw.writer, &session,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"navgraph.where","arguments":{"file":"app.zig","line":7}}}
    ));
    try testing.expect(try handleServerRequest(&aw.writer, &session,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"navgraph.context","arguments":{"symbol":"run","budget":0}}}
    ));
    try testing.expect(try handleServerRequest(&aw.writer, &session,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"navgraph.context","arguments":{"symbol":"nope_xyz"}}}
    ));
    try testing.expect(try handleServerRequest(&aw.writer, &session,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"navgraph.where","arguments":{"file":"app.zig"}}}
    ));
    try testing.expect(try handleServerRequest(&aw.writer, &session,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"navgraph.context","arguments":{"include":["bogus"],"symbol":"run"}}}
    ));
    try testing.expect(try handleServerRequest(&aw.writer, &session,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"navgraph.hunks","arguments":{"ref":"not-a-real-ref-xyz"}}}
    ));

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.written(), "\n"), '\n');
    var responses: [6]std.json.Parsed(std.json.Value) = undefined;
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) responses[count] = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer for (responses[0..count]) |*r| r.deinit();
    try testing.expectEqual(@as(usize, 6), count);

    const where_result = responses[0].value.object.get("result").?.object;
    try testing.expectEqualStrings("run", where_result.get("structuredContent").?.object.get("enclosing").?.object.get("name").?.string);

    // budget:0 does not error (silently reinterpreted as the 2000 default).
    const context_result = responses[1].value.object.get("result").?.object;
    try testing.expectEqualStrings("run", context_result.get("structuredContent").?.object.get("symbol").?.object.get("name").?.string);

    try testing.expectEqual(@as(i64, -32001), responses[2].value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(i64, -32602), responses[3].value.object.get("error").?.object.get("code").?.integer); // missing `line`
    try testing.expectEqual(@as(i64, -32602), responses[4].value.object.get("error").?.object.get("code").?.integer); // unknown include value
    try testing.expectEqual(@as(i64, -32002), responses[5].value.object.get("error").?.object.get("code").?.integer); // bad git ref
}

test "typed MCP facade covers six read-only surfaces with a stable bounded envelope" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false, fx.parsing());
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"map\",\"query\":\"leaf\",\"limit\":5}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"symbol\",\"selector\":\"leaf\",\"view\":\"definition\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"relations\",\"selector\":\"leaf\",\"view\":\"callers\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"source\",\"path\":\"app.zig\",\"start_line\":1,\"limit\":200,\"max_bytes\":1024}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"impact\",\"view\":\"edit_sites\",\"selector\":\"leaf\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"diagnostics\",\"view\":\"status\",\"limit\":1,\"max_bytes\":4096}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"source\",\"path\":\"app.zig\",\"selector\":\"leaf\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[\"rename\",\"leaf\",\"finish\",\"--preview\"]}}}",
    };
    for (requests) |request| try testing.expect(try handleServerRequest(&aw.writer, &session, request));

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var responses: [requests.len]std.json.Parsed(std.json.Value) = undefined;
    var response_count: usize = 0;
    defer for (responses[0..response_count]) |*response| response.deinit();
    while (lines.next()) |line| {
        responses[response_count] = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        response_count += 1;
    }
    try testing.expectEqual(requests.len, response_count);
    const operations = [_][]const u8{ "map", "symbol", "relations", "source", "impact", "diagnostics" };
    const first_snapshot = responses[0].value.object.get("result").?.object.get("structuredContent").?.object.get("snapshot_id").?.string;
    for (responses[0..operations.len], operations) |response, operation| {
        const result = response.value.object.get("result").?.object;
        try testing.expect(!result.get("isError").?.bool);
        const envelope = result.get("structuredContent").?.object;
        try testing.expectEqualStrings(agent_api.result_schema, envelope.get("schema").?.string);
        try testing.expectEqualStrings(operation, envelope.get("operation").?.string);
        try testing.expectEqualStrings(first_snapshot, envelope.get("snapshot_id").?.string);
        inline for (.{ "found", "exactness", "ambiguous", "candidates", "truncated", "next", "parse_health", "resolution_health", "warnings", "content", "items", "source_spans", "suggested_calls" }) |field|
            try testing.expect(envelope.get(field) != null);
    }
    const bounded = responses[3].value.object.get("result").?.object.get("structuredContent").?.object;
    const bounded_json = try std.json.Stringify.valueAlloc(testing.allocator, std.json.Value{ .object = bounded }, .{});
    defer testing.allocator.free(bounded_json);
    try testing.expect(bounded_json.len <= 1024);
    try testing.expect(bounded.get("next").? != .null);
    const bounded_items = bounded.get("items").?.array.items;
    try testing.expect(bounded_items.len > 0);
    const last_emitted_line = bounded_items[bounded_items.len - 1].object.get("line").?.integer;
    try testing.expectEqual(last_emitted_line + 1, bounded.get("next").?.object.get("start_line").?.integer);
    try testing.expectEqual(last_emitted_line, bounded.get("source_spans").?.array.items[0].object.get("end_line").?.integer);
    try testing.expectEqual(@as(i64, -32602), responses[6].value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(i64, -32602), responses[7].value.object.get("error").?.object.get("code").?.integer);
    try testing.expect(std.mem.indexOf(u8, responses[7].value.object.get("error").?.object.get("message").?.string, "read-only") != null);
}

test "typed MCP relations abstain before ambiguous calls and path traversal" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try ambiguousFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false, fx.parsing());
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"relations\",\"selector\":\"parse\",\"view\":\"callees\"}}}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"relations\",\"selector\":\"parse\",\"view\":\"path\",\"to\":\"tokenize\"}}}"));

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var response = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer response.deinit();
        const envelope = response.value.object.get("result").?.object.get("structuredContent").?.object;
        try testing.expect(envelope.get("ambiguous").?.bool);
        try testing.expect(envelope.get("content").? == .null);
        try testing.expectEqual(@as(usize, 0), envelope.get("items").?.array.items.len);
        try testing.expect(envelope.get("candidates").?.array.items.len >= 2);
        try testing.expect(envelope.get("suggested_calls").?.array.items.len >= 1);
        for (envelope.get("suggested_calls").?.array.items) |suggested| {
            const call = suggested.object;
            var selector_buf: [64]model.SymbolId = undefined;
            const selector = call.get("selector").?.string;
            try testing.expect(std.mem.indexOfScalar(u8, selector, '.') != null);
            try testing.expectEqual(@as(usize, 1), query.resolveIds(&fx.idx, selector, &selector_buf).len);
            if (call.get("to")) |to| {
                var to_buf: [64]model.SymbolId = undefined;
                try testing.expectEqual(@as(usize, 1), query.resolveIds(&fx.idx, to.string, &to_buf).len);
            }
        }
        if (count == 1) {
            var saw_from = false;
            var saw_to = false;
            for (envelope.get("candidates").?.array.items) |candidate| {
                const endpoint = candidate.object.get("endpoint").?.string;
                saw_from = saw_from or std.mem.eql(u8, endpoint, "from");
                saw_to = saw_to or std.mem.eql(u8, endpoint, "to");
            }
            try testing.expect(saw_from and saw_to);
            const suggestion = envelope.get("suggested_calls").?.array.items[0].object;
            try testing.expect(suggestion.get("selector") != null and suggestion.get("to") != null);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "MCP identity and capability surfaces share the live manifest contract" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false, fx.parsing());
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"navgraph/capabilities\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.capabilities\",\"arguments\":{}}}"));

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var responses: [4]std.json.Parsed(std.json.Value) = undefined;
    var response_count: usize = 0;
    defer for (responses[0..response_count]) |*response| response.deinit();
    while (lines.next()) |line| {
        responses[response_count] = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        response_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), response_count);

    const initialize = responses[0].value.object.get("result").?.object;
    try testing.expectEqualStrings(capabilities.mcp_protocol_version, initialize.get("protocolVersion").?.string);
    const server_version = initialize.get("serverInfo").?.object.get("version").?.string;
    try testing.expect(std.mem.startsWith(u8, server_version, capabilities.product_version));
    try testing.expect(std.mem.indexOf(u8, server_version, "src.") != null);
    const init_navgraph = initialize.get("capabilities").?.object.get("experimental").?.object.get("navgraph").?.object;
    try testing.expectEqualStrings(capabilities.capability_schema, init_navgraph.get("capabilitySchema").?.string);

    const tools = responses[1].value.object.get("result").?.object;
    // navgraph.query, navgraph (legacy), navgraph.capabilities, navgraph.reload,
    // navgraph.hunks, navgraph.context, navgraph.where.
    try testing.expectEqual(@as(usize, 7), tools.get("tools").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.capabilities") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.query") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.hunks") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.context") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.where") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "phase3") == null);
    try testing.expectEqualStrings(agent_api.tool_name, init_navgraph.get("queryTool").?.string);
    try testing.expectEqualStrings(agent_api.query_schema, init_navgraph.get("querySchema").?.string);
    try testing.expectEqualStrings(agent_api.result_schema, init_navgraph.get("resultSchema").?.string);
    try testing.expect(init_navgraph.get("agentSchemaHash") != null);

    const direct_manifest = responses[2].value.object.get("result").?.object;
    try testing.expectEqualStrings(capabilities.capability_schema, direct_manifest.get("schema").?.string);
    try testing.expect(direct_manifest.get("build").?.object.get("buildId") != null);
    try testing.expectEqualStrings(direct_manifest.get("schemaHash").?.string, init_navgraph.get("schemaHash").?.string);
    try testing.expectEqualStrings(direct_manifest.get("server").?.object.get("agentSchemaHash").?.string, init_navgraph.get("agentSchemaHash").?.string);

    const tool_result = responses[3].value.object.get("result").?.object;
    const manifest_text = tool_result.get("content").?.array.items[0].object.get("text").?.string;
    var manifest = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest_text, .{});
    defer manifest.deinit();
    try testing.expectEqualStrings(capabilities.capability_schema, manifest.value.object.get("schema").?.string);
    try testing.expect(std.mem.indexOf(u8, manifest_text, "\"name\":\"java\"") != null);
    try testing.expectEqualStrings(direct_manifest.get("schemaHash").?.string, manifest.value.object.get("schemaHash").?.string);
}

test "README and agent prompt carry the generated language inventory marker" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;
    const readme = try std.Io.Dir.cwd().readFileAlloc(io, "README.md", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(readme);
    const prompt = try std.Io.Dir.cwd().readFileAlloc(io, "prompt.md", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(prompt);

    var marker_buf: std.ArrayList(u8) = .empty;
    defer marker_buf.deinit(allocator);
    var marker_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &marker_buf);
    defer marker_writer.deinit();
    try marker_writer.writer.writeAll("navgraph-supported-languages: ");
    for (&@import("language.zig").supported, 0..) |language_desc, i| {
        if (i != 0) try marker_writer.writer.writeByte(',');
        try marker_writer.writer.writeAll(language_desc.name);
    }
    const marker = marker_writer.written();
    try testing.expect(std.mem.indexOf(u8, readme, marker) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, marker) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Anything else (Java") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "(`.java`)") != null);
}

test "README's command count claim matches command_descriptors.len" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;
    const readme = try std.Io.Dir.cwd().readFileAlloc(io, "README.md", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(readme);

    var marker_buf: [32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{d} commands", .{cli.registry.command_descriptors.len});
    try testing.expect(std.mem.indexOf(u8, readme, marker) != null);
}

test "server reload atomically refreshes requests and notifications" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false, fx.parsing());
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"));
    try testing.expect(has(aw.written(), "navgraph.reload"));
    try testing.expectEqual(@as(usize, 0), session.idx.lookup("freshAfterReload").len);
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "app.zig", .data = "pub fn freshAfterReload() void {}\n" });

    const before_notification = aw.written().len;
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"method\":\"workspace/reload\",\"params\":{\"noCache\":true}}"));
    try testing.expectEqual(before_notification, aw.written().len);
    try testing.expectEqual(@as(usize, 1), session.idx.lookup("freshAfterReload").len);

    try fx.tmp.dir.writeFile(io, .{ .sub_path = "app.zig", .data = "pub fn freshFromTool() void {}\n" });
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.reload\",\"arguments\":{\"noCache\":true}}}"));
    try testing.expectEqual(@as(usize, 1), session.idx.lookup("freshFromTool").len);
    try testing.expectEqual(@as(usize, 0), session.idx.lookup("freshAfterReload").len);
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.reload\",\"arguments\":{\"unknown\":true}}}"));
    try testing.expectEqual(@as(usize, 1), session.idx.lookup("freshFromTool").len);

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var responses: u32 = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        responses += 1;
    }
    try testing.expectEqual(@as(u32, 3), responses);
    try testing.expect(has(aw.written(), "index reloaded"));
    try testing.expect(has(aw.written(), "\"error\":{\"code\":-32602"));
}

test "failed server reload preserves the previous index" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "only.zig", .data = "pub fn stillIndexed() void {}\n" });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/only.zig", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var registry = backends.Registry.init(testing.allocator);
    defer registry.deinit();
    var session = try ServerSession.init(testing.allocator, io, &idx, root, false, .{ .choice = .auto, .registry = &registry });
    defer session.deinit();
    try testing.expectEqual(@as(usize, 1), idx.lookup("stillIndexed").len);
    try tmp.dir.deleteFile(io, "only.zig");

    if (session.reload(false)) |_| return error.ReloadOfMissingRootSucceeded else |err| {
        try testing.expect(@errorName(err).len > 0);
    }
    try testing.expectEqual(@as(usize, 1), idx.lookup("stillIndexed").len);
}
