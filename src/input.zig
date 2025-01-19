const std = @import("std");
const zglfw = @import("zglfw");
const render = @import("render/zgpu_backend/render.zig");

var go_left = false;
var go_right = false;
var go_forward = false;
var go_back = false;
var go_up = false;
var go_down = false;
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
                .w => go_forward = true,
                .s => go_back = true,
                .space => go_up = true,
                .left_shift => go_down = true,
                else => {},
            }
        },
        .release => {
            switch (key) {
                .a => go_left = false,
                .d => go_right = false,
                .w => go_forward = false,
                .s => go_back = false,
                .space => go_up = false,
                .left_shift => go_down = false,
                else => {},
            }
        },
        .repeat => {},
    }
}

pub fn updateCameraPosition(window: *zglfw.Window) void {
    const x, const y = window.getCursorPos();
    render.camera.yaw = @floatCast(-std.math.degreesToRadians(x / 2));
    render.camera.pitch = @floatCast(-std.math.clamp(std.math.degreesToRadians(y / 2), -std.math.pi / 2.0 + 0.1, std.math.pi / 2.0 - 0.1));
    render.camera.pos[0] -= 0.1 * @as(f32, @floatFromInt(@intFromBool(go_left)));
    render.camera.pos[0] += 0.1 * @as(f32, @floatFromInt(@intFromBool(go_right)));
    render.camera.pos[1] += 0.1 * @as(f32, @floatFromInt(@intFromBool(go_up)));
    render.camera.pos[1] -= 0.1 * @as(f32, @floatFromInt(@intFromBool(go_down)));
    render.camera.pos[2] += 0.1 * @as(f32, @floatFromInt(@intFromBool(go_forward)));
    render.camera.pos[2] -= 0.1 * @as(f32, @floatFromInt(@intFromBool(go_back)));
}