const std = @import("std");
const builtin = @import("builtin");
const util = @import("../../util.zig");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");

pub fn init(window: *zglfw.Window, ally: std.mem.Allocator) void {
    const gctx = zgpu.GraphicsContext.create(
        ally,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),

            // optional fields
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{}, // default context creation options
    ) catch |e| util.exitWithError(util.init_logger, "Error initiating graphics context: {any}", .{e});
    _ = gctx; // autofix
}

pub fn deinit() void {
    @panic("TODO");
}

pub fn draw() void {
    @panic("TODO");
}

pub fn getFrameTimeMs() u64 {
    @panic("TODO");
}
