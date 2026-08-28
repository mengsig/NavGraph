pub fn Box(comptime T: type) type {
    return struct {
        value: T,

        pub fn init(value: T) @This() {
            return .{ .value = value };
        }

        pub fn get(self: @This()) T {
            return self.value;
        }
    };
}

const Operation = enum { symbol, relations };

fn symbol() void {}

pub fn decode(operation: Operation) void {
    switch (operation) {
        .symbol => {},
        .relations => {},
    }
}
