//! NavGraph editor server (`navgraph lsp`): a resident LSP server over stdio
//! that keeps the whole code graph in memory.
//!
//! Layering, outermost first — each layer depends only on the ones below it:
//!   loop      the stdio run loop, timers and logging
//!   handlers  method dispatch (standard LSP + navgraph/*)
//!   queries   query adapters over a live Index
//!   payload   the contract's JSON shapes
//!   session   the resident index: overlays, re-index, watcher
//!   overlay / position / rpc   leaf utilities, IO-free and directly testable
//!
//! The protocol is documented in `docs/lsp.md`.

pub const rpc = @import("lsp/rpc.zig");
pub const overlay = @import("lsp/overlay.zig");
pub const position = @import("lsp/position.zig");
pub const session = @import("lsp/session.zig");
pub const payload = @import("lsp/payload.zig");
pub const regex = @import("lsp/regex.zig");
pub const search = @import("lsp/search.zig");
pub const queries = @import("lsp/queries.zig");
pub const handlers = @import("lsp/handlers.zig");
pub const loop = @import("lsp/loop.zig");

pub const Options = loop.Options;
pub const run = loop.run;

test {
    @import("std").testing.refAllDecls(@This());
}
