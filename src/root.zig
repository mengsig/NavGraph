//! NavGraph library root: re-exports the modules so `zig build test` covers
//! them and downstream consumers can embed the graph engine.

pub const language = @import("language.zig");
pub const lexer = @import("lexer.zig");
pub const model = @import("model.zig");
pub const api = @import("api.zig");
pub const parser = @import("parser.zig");
pub const index = @import("index.zig");
pub const query = @import("query.zig");
pub const render = @import("render.zig");
pub const cli = @import("cli.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
