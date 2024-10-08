const std = @import("std");
const builtin = @import("builtin");
const zglfw = @import("zglfw");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;

const enable_debug = builtin.mode == .Debug;

const WIDTH = 800;
const HEIGHT = 600;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{.scope =.bgfx, .level = .warn },
    },
};

const init_log = std.log.scoped(.init);

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

    init_log.debug("zglfw setup took {d}us", .{t2 - t});

    // TODO: is this undefined valid?
    var bgfx_init: bgfx.Init = undefined;
    bgfx.initCtor(&bgfx_init);

    const framebuffer_size = window.getFramebufferSize();
    bgfx_init.resolution.width = @intCast(framebuffer_size[0]);
    bgfx_init.resolution.height = @intCast(framebuffer_size[1]);
    bgfx_init.debug = enable_debug;
    
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

    // init bgfx
    _ = bgfx.renderFrame(-1);
    if(!bgfx.init(&bgfx_init)) exitWithError("Failed to init bgfx", .{});
    defer bgfx.shutdown();
    
    bgfx.setViewClear(0,bgfx.ClearFlags_Color | bgfx.ClearFlags_Depth, 0x00FF0000, 1.0, 0);

    const reset_flags = bgfx.ResetFlags_None;
    // TODO: put this behind a flag
    // reset_flags |= bgfx.ResetFlags_Vsync;

    //
    // Reset and clear
    //
    bgfx.reset(bgfx_init.resolution.width, bgfx_init.resolution.height, reset_flags, bgfx_init.resolution.format);
    
    while (!window.shouldClose()) {
        zglfw.pollEvents();
        bgfx.touch(0);
        bgfx.setViewRect(0, 0, 0, WIDTH, HEIGHT);

        // false turns off frame capturing
        _ = bgfx.frame(false);
    }
}

fn exitWithError(comptime fmt_str: []const u8, args: anytype) noreturn {
    init_log.err(fmt_str, args);
    std.process.exit(1);
}

fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
    _ = scancode; // keeping for future
    _ = mods; // keeping for future
    if(key == .escape and action == .press) window.setShouldClose(true);
}