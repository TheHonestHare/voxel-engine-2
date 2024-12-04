const std = @import("std");
const math = std.math;
const zmath = @import("zmath");

pub const Camera = @This();

pos: [3]f32,
pitch: f32,
yaw: f32,
roll: f32 = 0,
fov: f32,
asp_rat: f32,
near: f32,
far: f32,

pub fn test_defaults(pos: [3]f32, asp_rat: f32) Camera {
    return .{
        .pos = pos,
        .pitch = 0,
        .yaw = 0,
        .roll = 0,
        .fov = math.degreesToRadians(70),
        .asp_rat = asp_rat,
        // TODO: sensible defaults
        .near = 0.5,
        .far = 200,
    };
}

pub fn updateAspectRatio(camera: *Camera, width: f32, height: f32) void {
    camera.asp_rat = width / height;
}

pub fn getPerspectiveMat(camera: *const Camera) zmath.Mat {
    return zmath.perspectiveFovLh(camera.fov, camera.asp_rat, camera.near, camera.far);
}

// TODO: quaternion magic so faster, maybe return a rotation matrix + vector offset
pub fn getCameraSpaceMat(camera: *const Camera) zmath.Mat {
    const pos_vec = zmath.loadArr3(camera.pos);

    const dir_vec = dir_vec: {
        const original_dir = zmath.loadArr3(.{ 1, 0, 0 });
        const yawed_dir = zmath.mul(zmath.rotationY(camera.yaw), original_dir);
        break :dir_vec zmath.mul(zmath.rotationZ(camera.pitch), yawed_dir);
    };
    const up_vec = up_vec: {
        const original_dir = zmath.loadArr3(.{ 0, 1, 0 });
        break :up_vec zmath.mul(zmath.rotationX(camera.roll), original_dir);
    };
    return zmath.lookToLh(pos_vec, dir_vec, up_vec);
}
