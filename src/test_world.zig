const std = @import("std");
const World = @import("BlockWorld.zig");

pub const test_texture_1: World.ImageTexture = blk: {
    var tmp: World.ImageTexture = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            if (y < 4) {
                tmp[y][x] = if (x < 4) .{ .r = 200, .g = 200, .b = 0 } else .{ .r = 0, .g = 0, .b = 200 };
            } else {
                tmp[y][x] = if (x < 4) .{ .r = 0, .g = 0, .b = 200 } else .{ .r = 200, .g = 200, .b = 0 };
            }
        }
    }
    break :blk tmp;
};

pub const test_texture_2 = loadBMP(@embedFile("test_texture.bmp"));

/// reads a 24-bit bmp (will not work on literally any other)
pub fn loadBMP(str: [:0]const u8) World.ImageTexture {
    //@compileLog(str);
    const pixel_array_offset = std.mem.readInt(u32, str[0x0A .. 0x0D + 1], .little);
    const byte_array = str[pixel_array_offset..][0 .. 8 * 8 * 3];
    var res: World.ImageTexture = undefined;
    var i: usize = 0;
    while (i < 8) {
        defer i += 1;

        var j: usize = 0;
        while (j < 8) {
            defer j += 1;
            res[i][j] = .{
                .r = byte_array[(i * 8 + j) * 3 + 2],
                .g = byte_array[(i * 8 + j) * 3 + 1],
                .b = byte_array[(i * 8 + j) * 3],
            };
        }
    }
    return res;
}

pub fn init_world(ally: std.mem.Allocator) !World {
    return World.init(ally, .{ 10, 1, 10 }, undefined, struct {
        pub fn populate(block_materials: *World.Chunk.BlockMaterials, chunk_x: u32, chunk_y: u32, chunk_z: u32, userpointer: *anyopaque) ?void {
            _ = chunk_y; // autofix
            _ = userpointer; // autofix
            const size = World.Chunk.CHUNK_SIZE;
            for (0..size) |y| {
                for (0..size) |z| {
                    for (0..size) |x| {
                        const position: [2]f32 = .{ @floatFromInt(x + chunk_x * size), @floatFromInt(z + chunk_z * size) };
                        const len = std.math.hypot(position[0], position[1]);
                        if (@round(@sin(len * std.math.pi / 4.0) * 3 + 5 - @as(f32, @floatFromInt(y))) > 0) {
                            block_materials[x + z * size + y * size * size] = if (@sin(len / 10) > 0) 1 else 2;
                        } else {
                            block_materials[x + z * size + y * size * size] = 0;
                        }
                    }
                }
            }
        }
    }.populate, &.{ test_texture_1, test_texture_2 }, &.{ @splat(0), @splat(1) });
}
