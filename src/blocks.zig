//! The world is composed of giant 32x32x32 cubes of "chunks"
//! Each chunk is 8x8x8 big, with bitmaps for determining blank space in 1x1x1, 2x2x2, and 4x4x4

const std = @import("std");

/// scale factor of big chunks to blocks
pub const BIG_CHUNK_TO_BLOCK = BIG_CHUNK_TO_CHUNK * CHUNK_TO_BLOCK;
pub const BIG_CHUNK_TO_CHUNK = 32;
pub const CHUNK_TO_BLOCK = 8;

pub const World = struct {
    pub const BigChunkCoordinate = struct { x: i32, z: i32, y: i32 };
    ally: std.mem.Allocator,

    /// defines the bottom left corner of the world, in big chunk coordinates (i.e. 128x128x128 cubes)
    botleft: BigChunkCoordinate,
    /// the coordinate diagonal to the top right corner of the world, in big chunk coordinates (i.e. 128x128x128 cubes). Done this way so subtraction gives length of the sides
    topright: BigChunkCoordinate,
    /// stored in x, z, y order ascending
    big_chunks: []BigChunk,

    pub fn init(
        ally: std.mem.Allocator,
        botleft: BigChunkCoordinate,
        topright: BigChunkCoordinate,
        initBigChunkFn: *const fn (std.mem.Allocator, BigChunkCoordinate) std.mem.Allocator.Error!BigChunk,
    ) std.mem.Allocator.Error!World {
        std.debug.assert(botleft.x < topright.x);
        std.debug.assert(botleft.z < topright.z);
        std.debug.assert(botleft.y < topright.y);

        const x_len, const z_len, const y_len = bounding_lengths(botleft, topright);
        const chunk_buff = try ally.alloc(BigChunk, x_len * z_len * y_len);
        errdefer ally.free(chunk_buff);

        var errdefer_count: usize = 0;
        errdefer for (0..errdefer_count) |i| {
            chunk_buff[i].deinit(ally);
        };

        var i_x = botleft.x;
        while (i_x < topright.x) {
            defer i_x += 1;

            var i_z = botleft.z;
            while (i_z < topright.z) {
                defer i_z += 1;

                var i_y = botleft.y;
                while (i_y < topright.y) {
                    defer i_y += 1;

                    const chunk_coords: BigChunkCoordinate = .{ .x = i_x, .z = i_z, .y = i_y };
                    chunk_buff[big_chunks_index(botleft, topright, chunk_coords) catch unreachable] = try initBigChunkFn(ally, chunk_coords);
                    errdefer_count += 1;
                }
            }
        }
        return .{
            .ally = ally,
            .botleft = botleft,
            .topright = topright,
            .big_chunks = chunk_buff,
        };
    }

    pub fn deinit(self: *const World) void {
        for (self.big_chunks) |*big_chunk| {
            big_chunk.deinit(self.ally);
        }
        self.ally.free(self.big_chunks);
    }

    pub inline fn bounding_lengths(botleft: BigChunkCoordinate, topright: BigChunkCoordinate) [3]u32 {
        std.debug.assert(botleft.x < topright.x);
        std.debug.assert(botleft.z < topright.z);
        std.debug.assert(botleft.y < topright.y);

        return .{
            @intCast(topright.x - botleft.x),
            @intCast(topright.z - botleft.z),
            @intCast(topright.y - botleft.y),
        };
    }

    /// parameters are 3 BLOCK coordinates
    pub fn setBlockEmpty(self: *const World, x: i64, z: i64, y: i64) (error{OutOfBoundingBox} || std.mem.Allocator.Error)!void {
        const big_chunk_coordinate: BigChunkCoordinate = .{
            @divFloor(x, BIG_CHUNK_TO_BLOCK),
            @divFloor(z, BIG_CHUNK_TO_BLOCK),
            @divFloor(y, BIG_CHUNK_TO_BLOCK),
        };
        const index = big_chunks_index(self.botleft, self.topright, big_chunk_coordinate) catch return error.OutOfBoundingBox;
        return self.big_chunks[index].setBlockEmpty(self.ally, .{
            .x = x % BIG_CHUNK_TO_BLOCK,
            .z = z % BIG_CHUNK_TO_BLOCK,
            .y = y % BIG_CHUNK_TO_BLOCK,
        });
    }

    pub fn setBlockData(self: *const World, x: i64, z: i64, y: i64, data: UniqueBlockData) (error{OutOfBoundingBox} || std.mem.Allocator.Error)!void {
        const big_chunk_coordinate: BigChunkCoordinate = .{
            @divFloor(x, BIG_CHUNK_TO_BLOCK),
            @divFloor(z, BIG_CHUNK_TO_BLOCK),
            @divFloor(y, BIG_CHUNK_TO_BLOCK),
        };
        const index = big_chunks_index(self.botleft, self.topright, big_chunk_coordinate) catch return error.OutOfBoundingBox;
        return self.big_chunks[index].setBlockData(self.ally, .{
            .x = x % BIG_CHUNK_TO_BLOCK,
            .z = z % BIG_CHUNK_TO_BLOCK,
            .y = y % BIG_CHUNK_TO_BLOCK,
        }, data);
    }

    // TODO: test this
    pub fn big_chunks_index(botleft: BigChunkCoordinate, topright: BigChunkCoordinate, coords: BigChunkCoordinate) error{OutOfBoundingBox}!usize {

        // assert that the coords land within the world box
        if (!(botleft.x <= coords.x and coords.x < topright.x and
            botleft.z <= coords.z and coords.z < topright.z and
            botleft.y <= coords.y and coords.y < topright.y)) return error.OutOfBoundingBox;

        const x_len, const z_len, _ = bounding_lengths(botleft, topright);
        // these are `coords` but with botleft as 0, 0, 0
        const rel_x: u32, const rel_z: u32, const rel_y: u32 = .{
            @intCast(coords.x - botleft.x),
            @intCast(coords.z - botleft.z),
            @intCast(coords.y - botleft.y),
        };

        return @intCast(rel_y * z_len * x_len + rel_z * x_len + rel_x);
    }
};

// TODO: do we want more bitmaps?
// TODO: currently, after a while of being run chunk_indices will point to random spots in chunk_list rather than being contiguous. Do deferred cleanup to slowly fix this over multiple frames
const BigChunk = struct {
    // TODO: create a custom MultiArrayList which can handle bare unions
    /// storage of all chunks in no particular order, to be indexed by the indices
    chunk_list: std.MultiArrayList(Chunk),
    /// storage for indices of where to find data, of length 32x32x32
    chunk_indices: [*]ChunkIndex,

    /// keep track of which chunks have been updated, in case another module needs to update its internal data structure (eg for rendering)
    update_list: std.ArrayListUnmanaged(ChunkCoords),

    pub fn initEmpty(ally: std.mem.Allocator) std.mem.Allocator.Error!BigChunk {
        const chunk_indices = try ally.alloc(ChunkIndex, 32 * 32 * 32);
        @memset(chunk_indices, .sentinel);
        return .{
            .chunk_list = .{},
            .chunk_indices = chunk_indices.ptr,
            .update_list = .empty,
        };
    }
    // wrapper so it can be passed into World.init
    pub fn initEmptyWrapper(ally: std.mem.Allocator, _: World.BigChunkCoordinate) std.mem.Allocator.Error!BigChunk {
        return @call(.always_inline, initEmpty, .{ally});
    }

    pub fn deinit(self: *BigChunk, ally: std.mem.Allocator) void {
        ally.free(self.chunk_indices[0 .. 32 * 32 * 32]);
        self.chunk_list.deinit(ally);
        self.update_list.deinit(ally);
    }

    pub const BlockInBigCoords = packed struct(u27) {
        x: BlockCoord,
        z: BlockCoord,
        y: BlockCoord,

        pub inline fn toChunkCoords(self: BlockInBigCoords) ChunkIndex.ChunkCoords {
            const scale = CHUNK_TO_BLOCK;
            return .{ .x = self.x / scale, .y = self.y / scale, .z = self.z / scale };
        }

        pub inline fn toChunkSubCoords(self: BlockInBigCoords) Chunk.SubCoords {
            return .{ .x = self.x % CHUNK_TO_BLOCK, .y = self.y % CHUNK_TO_BLOCK, .z = self.z % CHUNK_TO_BLOCK };
        }
    };

    pub const BlockCoord = std.math.IntFittingRange(0, BIG_CHUNK_TO_BLOCK - 1);

    // TODO: introduce 2 allocators (one for the update list, one for everything else)
    /// returns true if the entire big chunk can be freed
    pub fn setBlockEmpty(self: *const BigChunk, ally: std.mem.Allocator, coords: BlockInBigCoords) bool {
        // first checks if the entire chunk is non empty
        if (self.chunk_indices[coords.toChunkIndex()].getIndex()) |big_index| {
            // unsets the block in the high res bitmap
            const slices = self.chunk_list.slice();
            const high_bitmap_ptr = &slices.items(.high)[big_index];
            const mid_bitmap_ptr = &slices.items(.mid)[big_index];
            const low_bitmap_ptr = &slices.items(.low)[big_index];

            const subchunk_coords = coords.toChunkSubCoords();

            const high_index = subchunk_coords.toResIndex(.high);
            const mid_index = subchunk_coords.toResIndex(.mid);
            const low_index = subchunk_coords.toResIndex(.low);

            // if the chunk could have been freed it would have happened already (TODO: test this lol)
            if (low_bitmap_ptr.mask == 0) return false;
            high_bitmap_ptr.unset(high_index);

            if (Chunk.shouldMidBeSet(high_bitmap_ptr, subchunk_coords) == mid_bitmap_ptr.isSet(mid_index)) return false;
            mid_bitmap_ptr.toggle(mid_index);

            if (Chunk.shouldLowBeSet(mid_bitmap_ptr, subchunk_coords)) return false;
            low_bitmap_ptr.toggle(low_index);

            // TODO: use a deferred cleanup, shrinkAndFree
            if (low_bitmap_ptr.mask != 0) return false else {
                @branchHint(.unlikely);
            }
            // the chunk has been completely emptied and should be freed
            const sparse_index_to_update = self.chunk_list.items(.sparse_array_index)[self.chunk_list.len - 1];
            self.chunk_list.swapRemove(big_index);
            self.chunk_indices[sparse_index_to_update].index = big_index;
            self.chunk_indices[big_index].invalidate();

            self.update_list.append(ally, coords.toChunkCoords());
            // TODO: return true sometimes
            return false;
        }
    }

    /// Sets a blocks unique data to data. Cannot be the "empty block"
    pub fn setBlockData(self: *const BigChunk, ally: std.mem.Allocator, coords: BlockInBigCoords, data: UniqueBlockData) std.mem.Allocator.Error!void {
        //const x, const y, const z = .{coords.x, coords.y, coords.z};
        const big_index = coords.toIndex();

        const index = if (self.chunk_indices[big_index].getIndex()) |index| blk: {
            @branchHint(.likely);
            break :blk index;
        } else blk: {
            @branchHint(.unlikely);
            // we must create a chunk
            const new_index = try self.chunk_list.addOne(ally);
            const slice = self.chunk_list.slice();

            slice.items(.low)[new_index] = .initEmpty();
            slice.items(.mid)[new_index] = .initEmpty();
            slice.items(.high)[new_index] = .initEmpty();
            slice.items(.sparse_array_index)[new_index] = coords.toChunkCoords();
            break :blk new_index;
        };

        const slice = self.chunk_list.slice();
        const sub_coords = coords.toChunkSubCoords();
        slice.items(.low)[index].set(sub_coords.toResIndex(.low));
        slice.items(.mid)[index].set(sub_coords.toResIndex(.mid));
        slice.items(.high)[index].set(sub_coords.toResIndex(.high));
        slice.items(.unique_data)[index][sub_coords] = data;

        self.update_list.append(ally, coords.toChunkCoords());
    }
};

/// 8x8x8 array of the block data, or an index to the next empty node if empty
pub const Chunk = struct {
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

    pub fn initMidAndLowFromHigh(high: *const std.bit_set.ArrayBitSet(u64, 8 * 8 * 8)) struct { std.bit_set.IntegerBitSet(4 * 4 * 4), std.bit_set.IntegerBitSet(2 * 2 * 2) } {
        const mid: std.bit_set.IntegerBitSet(4 * 4 * 4) = .initEmpty();
        const low: std.bit_set.IntegerBitSet(2 * 2 * 2) = .initEmpty();

        for (0..4 * 4 * 4) |i| {
            const coords: SubCoords = .{ .x = @intCast((i & 0b00_00_11) * 2), .z = @intCast((i & 0b00_11_00) * 2), .y = @intCast((i & 0b11_00_00) * 2) };
            mid.setValue(i, shouldMidBeSet(high, coords));
        }
        for (0..2 * 2 * 2) |i| {
            const coords: SubCoords = .{ .x = @intCast((i & 0b001) * 4), .z = @intCast((i & 0b010) * 4), .y = @intCast((i & 0b100) * 4) };
            low.setValue(i, shouldLowBeSet(mid, coords));
        }
    }

    pub fn isSubEmpty(self: *const Chunk, coords: SubCoords, comptime res: Resolution) bool {
        const index = coords.toResIndex(res);
        return switch (res) {
            .high => self.high.isSet(index),
            .mid => self.mid.isSet(index),
            .low => self.low.isSet(index),
        };
    }

    // TODO: test this I'm suspicious
    /// tests if mid should be set using HIGH mask
    pub fn shouldMidBeSet(high: *const std.bit_set.ArrayBitSet(u64, 8 * 8 * 8), coords: SubCoords) bool {
        const x, const y, const z = .{ coords.x, coords.y, coords.z };
        // check the bottom square
        const base_mask = 0b11_00_00_00_11 << (z / 2 * 2 * 8 + x / 2 * 2);
        if (!high.masks[y / 2 * 2] & base_mask > 0) return false;
        // check the top square
        return high.masks[y / 2 * 2 + 1] & base_mask > 0;
    }

    /// tests if low should be set using MID mask
    /// you should probably always do shouldMidBeSet logic first so mid is up to date
    pub fn shouldLowBeSet(mid: std.bit_set.IntegerBitSet(4 * 4 * 4), coords: SubCoords) bool {
        const x, const y, const z = .{ coords.x, coords.y, coords.z };
        // check the bottom square
        const mask: u64 = blk: {
            std.debug.assert(0xF == 0b1111);
            std.debug.assert(0xC == 0b1100);
            std.debug.assert(0x0 == 0b0000);
            // create a mask for the bottom most layer
            // x mask
            const mask1 = 0x00_00_FF_FF;
            if (x > 3) mask1 = ~mask1;
            // z mask
            const mask2 = 0xCC_CC_CC_CC;
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

    pub const SubCoords = packed struct(u9) {
        x: BlockCoord,
        z: BlockCoord,
        y: BlockCoord,

        pub inline fn toIndex(self: SubCoords) u9 {
            return @bitCast(self);
        }

        pub inline fn toResIndex(self: SubCoords, res: Resolution) u9 {
            const x, const y, const z = .{ self.x, self.y, self.z };
            const scale_factor = switch (res) {
                .high => return self.toIndex(),
                .mid => 2,
                .low => 4,
            };
            const x_, const y_, const z_ = .{ x / scale_factor, y / scale_factor, z / scale_factor };
            return y_ * CHUNK_TO_BLOCK * CHUNK_TO_BLOCK + z_ * CHUNK_TO_BLOCK + x_;
        }
    };

    pub const BlockCoord = std.math.IntFittingRange(0, CHUNK_TO_BLOCK - 1);
};

pub const ChunkCoords = packed struct(u15) {
    x: std.math.IntFittingRange(0, 32 - 1),
    z: std.math.IntFittingRange(0, 32 - 1),
    y: std.math.IntFittingRange(0, 32 - 1),

    pub fn toIndex(self: ChunkCoords) u15 {
        return @bitCast(self);
    }
    pub fn fromIndex(index: u15) ChunkCoords {
        return @bitCast(index);
    }
};

/// index with a sentinel for maxInt(u16)
const ChunkIndex = struct {
    index: u16,

    pub const sentinel: ChunkIndex = .{ .index = std.math.maxInt(u16) };

    pub fn getIndex(self: @This()) ?u15 {
        return if (self.index == sentinel.index) null else @intCast(self.index);
    }

    pub fn invalidate(self: *@This()) void {
        self = sentinel;
    }
};

const UniqueBlockData = struct {
    material: u16,
};

const expectEql = std.testing.expectEqual;

test "Empty World" {
    const world: World = try .init(std.testing.allocator, .{ .x = -3, .z = -2, .y = 1 }, .{ .x = -2, .z = 3, .y = 3 }, &BigChunk.initEmptyWrapper);
    defer world.deinit();

    const box_lengths = World.bounding_lengths(world.botleft, world.topright);
    try expectEql(1, box_lengths[0]);
    try expectEql(5, box_lengths[1]);
    try expectEql(2, box_lengths[2]);

    for (world.big_chunks) |*big_chunk| {
        for (big_chunk.chunk_indices[0 .. 32 * 32 * 32]) |index| {
            try std.testing.expect(index.getIndex() == null);
        }
    }
}
