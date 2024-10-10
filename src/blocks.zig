//! The world is composed of giant 32x32x32 cubes of "chunks"
//! Each chunk is 8x8x8 big, with bitmaps for determining blank space in 1x1x1, 2x2x2, and 4x4x4

const std = @import("std");

/// scale factor of big chunks to blocks
pub const BIG_CHUNK_TO_BLOCK = BIG_CHUNK_TO_CHUNK * CHUNK_TO_BLOCK;
pub const BIG_CHUNK_TO_CHUNK = 32;
pub const CHUNK_TO_BLOCK = 8;

pub const World = struct {
    ally: std.mem.Allocator,
    size_x: u8,
    size_z: u8,
    size_y: u8,
    /// stored in x, z, y order ascending
    big_chunks: []BigChunk,

    // TODO: test this
    pub fn big_chunks_at(self: *const World, x: u8, y: u8, z: u8) *BigChunk {
        return self.big_chunks[y * self.x * self.z + z * self.x + x];
    }
};

// TODO: do we want more bitmaps?
const BigChunk = struct {
    comptime {
        std.debug.assert(CHUNK_TO_BLOCK == 8);
    }
    /// storage of all chunks in no particular order, to be indexed by the indices
    chunk_list: std.MultiArrayList(Chunk),
    /// storage for indices of where to find data, of length 32x32x32
    chunk_indices: [*]ChunkIndex,

    const Chunk = struct {
        pub const Resolution = enum { high, mid, low };

        pub const high_to_mid_masks = blk: {
            // init return with all 0's
            var result: [4 * 4 * 4]std.bit_set.StaticBitSet(std.meta.Int(.unsigned, 8 * 8 * 8)) = undefined;
            @memset(&std.mem.sliceAsBytes(&result), 0);

            for (0..4 * 4 * 4) |bits| {
                const correct_y = bits & 0b11_00_00;
                const correct_z = bits & 0b00_11_00;
                const correct_x = bits & 0b00_00_11;
                for (0..8) |y| {
                    if (y / 2 != correct_y) continue;
                    for (0..8) |z| {
                        if (z / 2 != correct_z) continue;
                        for (0..8) |x| {
                            if (x / 2 != correct_x) continue;
                            result[bits].set(getIndexWithResolution(x, y, z, .high));
                        }
                    }
                }
            }
            break :blk result;
        };

        pub const mid_to_low_masks = blk: {
            // init return with all 0's
            var result: [2 * 2 * 2]std.bit_set.StaticBitSet(std.meta.Int(.unsigned, 4 * 4 * 4)) = undefined;
            @memset(&std.mem.sliceAsBytes(&result), 0);

            for (0..2 * 2 * 2) |bits| {
                const correct_y = bits & 0b100;
                const correct_z = bits & 0b010;
                const correct_x = bits & 0b001;
                for (0..4) |y| {
                    if (y / 2 != correct_y) continue;
                    for (0..4) |z| {
                        if (z / 2 != correct_z) continue;
                        for (0..4) |x| {
                            if (x / 2 != correct_x) continue;
                            result[bits].set(getIndexWithResolution(x, y, z, .mid));
                        }
                    }
                }
            }
            break :blk result;
        };

        /// data specific to each block (eg material)
        unique_data: [8 * 8 * 8]UniqueBlockData,
        // TODO: profile difference between a 512 bit integer and 64
        /// highest res bitmap for whether a block is empty. Laid out lowest x -> z -> y
        high: std.bit_set.ArrayBitSet(u64, 8 * 8 * 8),
        /// mid res bitmap for whether a 2x2x2 subchunk is empty. Laid out lowest x -> z -> y
        mid: std.bit_set.IntegerBitSet(4 * 4 * 4),
        /// low res bitmap for whether a 4x4x4 subchunk is empty. Laid out lowest x -> z -> y
        low: std.bit_set.IntegerBitSet(2 * 2 * 2),

        pub inline fn getIndexWithResolution(x: u3, y: u3, z: u3, res: Resolution) u9 {
            const scale_factor = switch (res) {
                .high => 1,
                .mid => 2,
                .low => 4,
            };
            const x_, const y_, const z_ = .{ x / scale_factor, y / scale_factor, z / scale_factor };
            return y_ * CHUNK_TO_BLOCK * CHUNK_TO_BLOCK + z_ * CHUNK_TO_BLOCK + x_;
        }

        pub fn isSubEmpty(self: *const Chunk, x: u3, y: u3, z: u3, res: Resolution) bool {
            const index = getIndexWithResolution(x, y, z, res);
            return switch (res) {
                .high => self.high.isSet(index),
                .mid => self.mid.isSet(index),
                .low => self.low.isSet(index),
            };
        }

        /// returns true if the entire chunk can be freed
        pub fn setEmpty(self: *const Chunk, x: u3, y: u3, z: u3) bool {
            self.high.unset(getIndexWithResolution(x, y, z, .high));
            return self.propogateUpdate(x, y, z);
        }

        pub fn addBlock(self: *const Chunk, x: u3, y: u3, z: u3, data: UniqueBlockData) void {
            const index = getIndexWithResolution(x, y, z, .high);
            self.unique_data[index] = data;
            self.high.set(index);
            std.debug.assert(!self.propogateUpdate()); // we should never be able to free if we add blocks
        }

        /// returns true if the entire chunk can be freed
        pub fn propogateUpdate(self: *const Chunk, x: u3, y: u3, z: u3) bool {
            const mid_index = getIndexWithResolution(x, y, z, .mid);
            const low_index = getIndexWithResolution(x, y, z, .low);

            if (self.shouldMidBeSet(x, y, z) != self.mid.isSet(mid_index)) {
                self.mid.toggle(mid_index);

                if (self.shouldLowBeSet(x, y, z) != self.low.isSet(low_index)) {
                    self.low.toggle(low_index);
                }
            }
            return self.low.mask == 0;
        }

        pub fn shouldMidBeSet(self: *const Chunk, x: u3, y: u3, z: u3) bool {
            // check the bottom square
            const base_mask = 0b11_00_00_00_11 << (z / 2 * 2 * 8 + x / 2 * 2);
            if (!self.high.masks[y / 2 * 2] & base_mask > 0) return false;
            // check the top square
            return self.high.masks[y / 2 * 2 + 1] & base_mask > 0;
        }

        pub fn shouldLowBeSet(self: *const Chunk, x: u3, y: u3, z: u3) bool {
            // check the bottom square
            const base_mask = blk: {
                // x mask
                var mask1 = 0x0000_0000_FFFF_FFFF;
                if (x > 3) mask1 = ~mask1;
                // z mask
                var mask2 = 0x0F0F_0F0F_0F0F_0F0F;
                if (z > 3) mask2 = ~mask2;

                break :blk mask1 & mask2;
            };
            if (!self.high.masks[y / 2 * 2] & base_mask > 0) return false;
            // check the top square
            return self.high.masks[y / 2 * 2 + 1] & base_mask > 0;
        }
    };
};

/// index with a sentinel for maxInt(u16)
const ChunkIndex = packed struct {
    index: u16,
    pub fn getIndex(self: @This()) ?u16 {
        return if (self.index == std.math.maxInt(u16)) null else self.index;
    }
};

const UniqueBlockData = struct {
    material: u16,
};
