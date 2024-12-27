const std = @import("std");
const util = @import("util.zig");
const zglfw = @import("zglfw");

const render = @import("render/zgpu_backend/render.zig");
const input = @import("input.zig");

const WIDTH = 800;
const HEIGHT = 600;
const ORIGINAL_TITLE = "Voxel engine";

pub const std_options: std.Options = .{
    .log_scope_levels = &.{},
};

pub fn main() !void {
    var t = std.time.microTimestamp();
    try zglfw.init();
    defer zglfw.terminate();
    zglfw.windowHintTyped(.client_api, .no_api);
    zglfw.windowHintTyped(.center_cursor, true);
    const window: *zglfw.Window = try .create(WIDTH, HEIGHT, ORIGINAL_TITLE, null);
    defer window.destroy();
    //window.setInputMode(.raw_mouse_motion, true);
    _ = window.setKeyCallback(input.keyCallback);
    var t2 = std.time.microTimestamp();
    util.init_logger.debug("zglfw setup took {d}us", .{t2 - t});

    t = std.time.microTimestamp();

    // TODO: choose better allocator based on release or debug
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    render.init(window, ally);
    t2 = std.time.microTimestamp();
    util.init_logger.debug("render setup took {d}us", .{t2 - t});
    defer render.deinit(ally);

    var title_buff: if (util.enable_debug) [100]u8 else void = undefined;
    var title_update_timer = if (util.enable_debug) std.time.Timer.start() catch unreachable else {};
    var fps: u32 = 0;

    while (!window.shouldClose()) {

        // print frame time to title
        if (util.enable_debug) blk: {
            // update every half second so its readable
            if (title_update_timer.read() > std.time.ns_per_s / 2) {
                title_update_timer.reset();
                const sub_buff = std.fmt.bufPrintZ(&title_buff, ORIGINAL_TITLE ++ "    [Frame time: {d}ms  |  FPS: {d}]", .{ render.getFrameTimeMs(), fps * 2 }) catch break :blk;
                window.setTitle(sub_buff);
                fps = 0;
            }
        }
        zglfw.pollEvents();
        render.draw();
        input.updateCameraPosition(window);
        fps += 1;
    }
}
