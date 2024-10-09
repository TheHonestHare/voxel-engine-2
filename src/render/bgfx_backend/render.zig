const std = @import("std");
const builtin = @import("builtin");
const util = @import("../../util.zig");
const zglfw = @import("zglfw");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;

// TODO: find out what this code actually does
var bgfx_callbacks = zbgfx.callbacks.CCallbackInterfaceT{
    .vtable = &zbgfx.callbacks.DefaultZigCallbackVTable.toVtbl(),
};
var bgfx_alloc: zbgfx.callbacks.ZigAllocator = undefined;
var bgfx_init: bgfx.Init = undefined;

var frame_time: u64 = 0;

pub fn init(window: *zglfw.Window) void {
    // TODO: is this undefined valid?
    //var bgfx_init: bgfx.Init = undefined;
    bgfx.initCtor(&bgfx_init);

    const framebuffer_size = window.getFramebufferSize();
    bgfx_init.resolution.width = @intCast(framebuffer_size[0]);
    bgfx_init.resolution.height = @intCast(framebuffer_size[1]);
    bgfx_init.debug = false;

    // FIXME: apparently this will panic according to the examples
    // bgfx_alloc = zbgfx.callbacks.ZigAllocator.init(&_allocator);
    // bgfx_init.allocator = &bgfx_alloc;

    bgfx_init.callback = &bgfx_callbacks;

    bgfx_init.platformData.ndt = null;
    switch (builtin.target.os.tag) {
        .linux => {
            bgfx_init.platformData.type = bgfx.NativeWindowHandleType.Default;
            bgfx_init.platformData.nwh = @ptrFromInt(zglfw.getX11Window(window));
            bgfx_init.platformData.ndt = zglfw.getX11Display();
        },
        .windows => {
            bgfx_init.platformData.nwh = zglfw.getWin32Window(window);
        },
        else => |v| if (v.isDarwin()) {
            bgfx_init.platformData.nwh = zglfw.getCocoaWindow(window);
        } else util.exitWithError("Error: platform not supported", .{}),
    }

    // init bgfx
    //_ = bgfx.renderFrame(-1);
    if (!bgfx.init(&bgfx_init)) util.exitWithError(util.init_logger, "Failed to init bgfx", .{});

    bgfx.setViewClear(0, bgfx.ClearFlags_Color | bgfx.ClearFlags_Depth, 0x00FF0000, 1.0, 0);

    const reset_flags = bgfx.ResetFlags_None;
    // TODO: put this behind a flag
    // reset_flags |= bgfx.ResetFlags_Vsync;

    // Applies the new settings
    bgfx.reset(bgfx_init.resolution.width, bgfx_init.resolution.height, reset_flags, bgfx_init.resolution.format);
}

pub fn deinit() void {
    bgfx.shutdown();
}

pub fn draw() void {
    // if we're on a system without a timer how tf are we gonna draw a voxel engine lmao + we're in debug so release modes should be fine
    var timer = if (util.enable_debug) std.time.Timer.start() catch unreachable else {};
    bgfx.touch(0);
    bgfx.setViewRect(0, 0, 0, @intCast(bgfx_init.resolution.width), @intCast(bgfx_init.resolution.height));

    // false turns off frame capturing
    _ = bgfx.frame(false);
    if (util.enable_debug) frame_time = timer.read() / 1000;
}

pub fn getFrameTime() u64 {
    return frame_time;
}
