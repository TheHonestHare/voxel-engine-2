const std = @import("std");
const zglfw = @import("zglfw");

pub fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
    _ = mods;
    _ = scancode;
    switch (key) {
        .escape => {
            if (action == .press) window.setShouldClose(true);
        },
        else => {},
    }
}
