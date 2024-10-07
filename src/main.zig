const std = @import("std");
const builtin = @import("builtin");
const zglfw = @import("zglfw");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;

const enable_debug = builtin.mode == .Debug;

const WIDTH = 800;
const HEIGHT = 600;

// TODO: find out what this code actually does
var bgfx_callbacks = zbgfx.callbacks.CCallbackInterfaceT{
    .vtable = &zbgfx.callbacks.DefaultZigCallbackVTable.toVtbl(),
};
var bgfx_alloc: zbgfx.callbacks.ZigAllocator = undefined;

pub fn main() !void {
    const t = std.time.microTimestamp();
    try zglfw.init();
    defer zglfw.terminate();
    zglfw.windowHintTyped(.client_api, .no_api);
    const window = try zglfw.Window.create(WIDTH, HEIGHT, "Voxel engine", null);
    defer window.destroy();
    _ = window.setKeyCallback(keyCallback);
    const t2 = std.time.microTimestamp();

    std.log.enable_debug("zglfw setup took {d}us", .{t2 - t});

    // TODO: is this undefined valid?
    var bgfx_init: bgfx.Init = undefined;
    bgfx.initCtor(&bgfx_init);

    const framebuffer_size = window.getFramebufferSize();
    bgfx_init.resolution.width = framebuffer_size[0];
    bgfx_init.resolution.height = framebuffer_size[1];
    bgfx_init.enable_debug = enable_debug;
    
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
        },
    }

    while (!window.shouldClose()) {
        zglfw.pollEvents();
    }
}

fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
    _ = scancode; // keeping for future
    _ = mods; // keeping for future
    if(key == .escape and action == .press) window.setShouldClose(true);
}