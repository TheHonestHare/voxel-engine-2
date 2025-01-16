const std = @import("std");
const builtin = @import("builtin");

pub const enable_debug = builtin.mode == .Debug;

pub const init_logger = std.log.scoped(.init);

pub fn exitWithError(logger: anytype, comptime fmt_str: []const u8, args: anytype) noreturn {
    logger.err(fmt_str, args);
    std.process.exit(1);
}

pub fn roundUp(n: anytype, multiple: anytype) @TypeOf(n, multiple) {
    return ((n + multiple - 1)) / multiple * multiple;
}
