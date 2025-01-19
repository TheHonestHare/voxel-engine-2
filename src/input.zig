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
    // zig PLEASE GET A BETTER CASTING SYSTEM THIS SUCKS
    const x, const y = window.getCursorPos();
    render.camera.yaw = @floatCast(-std.math.degreesToRadians(x / 2));
    render.camera.pitch = @floatCast(-std.math.clamp(std.math.degreesToRadians(y / 2), -std.math.pi / 2.0 + 0.1, std.math.pi / 2.0 - 0.1));

    // move camera vertically
    render.camera.pos[1] += 0.1 * @as(f32, @floatFromInt(@as(i8, @intFromBool(go_up)) - @as(i8, @intFromBool(go_down))));

    // move camera horizontally

    // The particular sin's and cos's are chosen because this is a coordinate system where theta = 0 points in +z, and theta = pi / 2 points in -x

    // direction the camera is facing
    const move_vector_para: [2]f32 = .{-@sin(render.camera.yaw), @cos(render.camera.yaw)};
    // move_vector_para rotated 90 degrees
    const move_vector_perp: [2]f32 = .{@cos(render.camera.yaw), @sin(render.camera.yaw)};

    const forward_delta: f32 = @floatFromInt(@as(i8, @intFromBool(go_forward)) - @as(i8, @intFromBool(go_back)));
    const right_delta: f32 = @floatFromInt(@as(i8, @intFromBool(go_right)) - @as(i8, @intFromBool(go_left)));

    const final_move_vec_x, const final_move_vec_z = blk: {
        const added_x = move_vector_para[0] * forward_delta + move_vector_perp[0] * right_delta;
        const added_z = move_vector_para[1] * forward_delta + move_vector_perp[1] * right_delta;
        const added_mag = @sqrt(added_x * added_x + added_z * added_z);

        // if the magnitude is 0, the character shouldn't be moving anyways so we avoid a divide by 0
        if (added_mag == 0) return;

        // normalize
        break :blk .{added_x / added_mag, added_z / added_mag};
    };


    std.debug.assert(@abs(final_move_vec_x * final_move_vec_x + final_move_vec_z * final_move_vec_z - 1) < 0.001);

    render.camera.pos[0] += 0.1 * final_move_vec_x;
    render.camera.pos[2] += 0.1 * final_move_vec_z;
}