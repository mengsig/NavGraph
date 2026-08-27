//! NavGraph editor server (`navgraph serve` / `navgraph lsp`): a resident
//! LSP server over stdio that keeps the whole code graph in memory.
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

pub const rpc = @import("serve/rpc.zig");
pub const overlay = @import("serve/overlay.zig");
pub const position = @import("serve/position.zig");
pub const session = @import("serve/session.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
