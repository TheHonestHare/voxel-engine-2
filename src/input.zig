const std = @import("std");
const zglfw = @import("zglfw");
const render = @import("render/zgpu_backend/render.zig");

var go_left = false;
var go_right = false;
pub fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
    _ = mods;
    _ = scancode;
    switch(action) {
        .press => {
            switch (key) {
                .escape => {
                    window.setShouldClose(true);
                },
                .a => go_left = true,
                .d => go_right = true,
                else => {},
            }
        },
        .release => {
            switch (key) {
                .a => go_left = false,
                .d => go_right = false,
                else => {},
            }
        },
        .repeat => {},
    }
}

pub fn updateCameraPosition(window: *zglfw.Window) void {
    const x, const y = window.getCursorPos();
    render.camera.yaw = @floatCast(std.math.degreesToRadians(x / 4));
    render.camera.pitch = @floatCast(std.math.degreesToRadians(y / 4));
    render.camera.pos[0] += 0.01 * @as(f32, @floatFromInt(@intFromBool(go_left)));
    render.camera.pos[0] -= 0.01 * @as(f32, @floatFromInt(@intFromBool(go_right)));
}