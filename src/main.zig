const std = @import("std");
const glfw = @import("zglfw");

pub fn main() !void {
    const t = std.time.microTimestamp();
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHintTyped(.client_api, .no_api);
    const window = try glfw.Window.create(800, 600, "Voxel engine", null);
    defer window.destroy();
    const t2 = std.time.microTimestamp();

    std.log.debug("Setup took {d}us", .{t2 - t});

    while(!window.shouldClose()) {
        glfw.pollEvents();
    }
}