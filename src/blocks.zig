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
    // TODO: create a custom MultiArrayList which can handle bare unions
    /// storage of all chunks in no particular order, to be indexed by the indices
    chunk_list: std.MultiArrayList(Chunk),
    /// storage for indices of where to find data, of length 32x32x32
    chunk_indices: [*]ChunkIndex,

    /// 8x8x8 array of the block data, or an index to the next empty node if empty
    const Chunk = struct {
        pub const Resolution = enum { high, mid, low };

        /// data specific to each block (eg material)
        unique_data: [8 * 8 * 8]UniqueBlockData,
        // TODO: profile difference between a 512 bit integer and array of 64 bit integer
        /// highest res bitmap for whether a block is empty. Laid out lowest x -> z -> y
        high: std.bit_set.ArrayBitSet(u64, 8 * 8 * 8),
        /// mid res bitmap for whether a 2x2x2 subchunk is empty. Laid out lowest x -> z -> y
        mid: std.bit_set.IntegerBitSet(4 * 4 * 4),
        /// low res bitmap for whether a 4x4x4 subchunk is empty. Laid out lowest x -> z -> y
        low: std.bit_set.IntegerBitSet(2 * 2 * 2),
        /// index back into the sparse array
        sparse_array_index: u27,

        pub fn isListNode(low: std.bit_set.IntegerBitSet(2 * 2 * 2)) bool {
            return low.mask == 0;
        }

        pub fn getNextEmptyIndex(mid: std.bit_set.IntegerBitSet(4 * 4 * 4), low: std.bit_set.IntegerBitSet(2 * 2 * 2)) ?u64 {
            if(!isListNode(low)) return null;
            return mid.mask;
        }

        pub inline fn getIndexWithResolution(x: u3, y: u3, z: u3, res: Resolution) u9 {
            const scale_factor = switch (res) {
                .high => 1,
                .mid => 2,
                .low => 4,
            };
            const x_, const y_, const z_ = .{ x / scale_factor, y / scale_factor, z / scale_factor };
            return y_ * CHUNK_TO_BLOCK * CHUNK_TO_BLOCK + z_ * CHUNK_TO_BLOCK + x_;
        }

        pub fn isSubEmpty(self: *const Chunk, x: u3, y: u3, z: u3, comptime res: Resolution) bool {
            const index = getIndexWithResolution(x, y, z, res);
            return switch (res) {
                .high => self.high.isSet(index),
                .mid => self.mid.isSet(index),
                .low => self.low.isSet(index),
            };
        }

        /// tests if mid should be set using HIGH mask
        pub fn shouldMidBeSet(high: *const std.bit_set.ArrayBitSet(u64, 8 * 8 * 8), x: u3, y: u3, z: u3) bool {
            // check the bottom square
            const base_mask = 0b11_00_00_00_11 << (z / 2 * 2 * 8 + x / 2 * 2);
            if (!high.masks[y / 2 * 2] & base_mask > 0) return false;
            // check the top square
            return high.masks[y / 2 * 2 + 1] & base_mask > 0;
        }

        /// tests if low should be set using MID mask
        /// you should probably always do shouldMidBeSet logic first so mid is up to date
        pub fn shouldLowBeSet(mid: std.bit_set.IntegerBitSet(4 * 4 * 4), x: u3, y: u3, z: u3) bool {
            // check the bottom square
            const mask: u64 = blk: {
                std.debug.assert(0xF == 0b1111);
                std.debug.assert(0xC == 0b1100);
                std.debug.assert(0x0 == 0b0000);
                // create a mask for the bottom most layer
                // x mask
                var mask1 = 0x00_00_FF_FF;
                if (x > 3) mask1 = ~mask1;
                // z mask
                var mask2 = 0xCC_CC_CC_CC;
                if (z > 3) mask2 = ~mask2;

                var mask = mask1 & mask2;
                // include the second layer as well
                mask = mask | (mask << 1 * 4 * 4);
                // put it at correct y level
                mask <<= y / 2 * 2;

                break :blk mask;
            };
            return mid.mask & mask > 0;
        }
    };

    pub const CoordInt = std.math.IntFittingRange(0, BIG_CHUNK_TO_BLOCK);

    pub fn calculateChunkIndex(x: CoordInt, y: CoordInt, z: CoordInt) u27 {
        return y * BIG_CHUNK_TO_CHUNK * BIG_CHUNK_TO_CHUNK + z * BIG_CHUNK_TO_CHUNK + x;
    }

    /// returns true if the entire big chunk can be freed
    pub fn setBlockEmpty(self: *const BigChunk, x: CoordInt, y: CoordInt, z: CoordInt) bool {
        // first checks if the entire chunk is non empty
        if(self.chunk_indices[calculateChunkIndex(x, y, z)].getIndex()) |big_index| {
            // unsets the block in the high res bitmap
            const slices = self.chunk_list.slice();
            const high_bitmap_ptr = &slices.items(.high)[big_index];
            const mid_bitmap_ptr = &slices.items(.mid)[big_index];
            const low_bitmap_ptr = &slices.items(.low)[big_index];

            const chunk_x, const chunk_y, const chunk_z = .{x % BIG_CHUNK_TO_CHUNK, y % BIG_CHUNK_TO_CHUNK, z % BIG_CHUNK_TO_CHUNK};

            const high_index = Chunk.getIndexWithResolution(chunk_x, chunk_y, chunk_z, .high);
            const mid_index = Chunk.getIndexWithResolution(chunk_x, chunk_y, chunk_z, .mid);
            const low_index = Chunk.getIndexWithResolution(chunk_x, chunk_y, chunk_z, .low);

            // if the chunk could have been freed it would have happened already
            if(Chunk.isListNode(low_bitmap_ptr.*)) return false;
            high_bitmap_ptr.unset(high_index);

            if(Chunk.shouldMidBeSet(high_bitmap_ptr, chunk_x, chunk_y, chunk_z) == mid_bitmap_ptr.isSet(mid_index)) return false;
            mid_bitmap_ptr.toggle(mid_index);

            if(Chunk.shouldLowBeSet(mid_bitmap_ptr, chunk_x, chunk_y, chunk_z)) return false;
            low_bitmap_ptr.toggle(low_index);

            // TODO: use a deferred cleanup
            if(low_bitmap_ptr.mask != 0) return false;
            // the chunk has been completely emptied and should be freed
            const sparse_index_to_update = self.chunk_list.items(.sparse_array_index)[self.chunk_list.len - 1];
            self.chunk_list.swapRemove(big_index);
            self.chunk_indices[sparse_index_to_update].index = big_index;
            self.chunk_indices[big_index].invalidate();
        }
        
    }
    // TODO:
    // pub fn setBlockNonEmpty(self: *const Chunk, x: u3, y: u3, z: u3, data: UniqueBlockData) void {
    //     const index = getIndexWithResolution(x, y, z, .high);
    //     self.unique_data[index] = data;
    //     self.high.set(index);
    //     std.debug.assert(!self.propogateUpdate()); // we should never be able to free if we add blocks
    // }
};

/// index with a sentinel for maxInt(u16)
const ChunkIndex = packed struct {
    index: u16,
    pub fn getIndex(self: @This()) u16 {
        return if (self.index == std.math.maxInt(u16)) null else self.index;
    }

    pub fn invalidate(self: *@This()) void {
        self.index = std.math.maxInt(u16);
    }
};

const UniqueBlockData = struct {
    material: u16,
};
