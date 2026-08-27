//! NavGraph library root: re-exports the modules so `zig build test` covers
//! them and downstream consumers can embed the graph engine.

pub const language = @import("language.zig");
pub const lexer = @import("lexer.zig");
pub const model = @import("model.zig");
pub const api = @import("api.zig");
pub const events = @import("events.zig");
pub const gitdiff = @import("gitdiff.zig");
pub const gitutil = @import("gitutil.zig");
pub const history = @import("history.zig");
pub const imports = @import("imports.zig");
pub const parser = @import("parser.zig");
pub const ts_backend = @import("ts_backend.zig");
pub const backends = @import("backends.zig");
pub const index = @import("index.zig");
pub const impls = @import("impls.zig");
pub const hierarchy = @import("hierarchy.zig");
pub const exception_scan = @import("exception_scan.zig");
pub const exceptions = @import("exceptions.zig");
pub const taint_graph = @import("taint_graph.zig");
pub const taint = @import("taint.zig");
pub const gitignore = @import("gitignore.zig");
pub const cache = @import("cache.zig");
pub const query = @import("query.zig");
pub const json_out = @import("json_out.zig");
pub const workflow = @import("workflow.zig");
pub const render = @import("render.zig");
pub const viz = @import("viz.zig");
pub const command_registry = @import("command_registry.zig");
pub const capabilities = @import("capabilities.zig");
pub const workspace_path = @import("workspace_path.zig");
pub const cli = @import("cli.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
