const std = @import("std");

pub const MaterialIndex = u16;
pub const ChunkPopulatorFn = *const fn(
    *Chunk.BlockMaterials, 
    *Chunk.BlockBitmap, 
    x: u32, 
    y: u32, 
    z: u32, 
    userpointer: *anyopaque,
) ?void;

ally: std.mem.Allocator,
chunk_arena_state: std.heap.ArenaAllocator.State,
dims: [3]u16,
/// indexes into the chunk_data grid, 0 meaning empty
sparse_chunk_grid: std.ArrayListUnmanaged(u32),
/// first element is always garbage and empty
chunk_data: std.MultiArrayList(Chunk),


/// chunk_populator should set the bitmask to 0 first
/// chunk_populator should return null if the chunk is unempty
pub fn init(ally: std.mem.Allocator, dims: [3]f32, userpointer: *anyopaque, chunk_populator: ChunkPopulatorFn) !@This() {
    var self: @This() = .{
        .ally = ally,
        .chunk_arena_state = .{},
        .dims = dims,
        .sparse_chunk_grid = .{},
        .chunk_data = .{},
    };
    var chunk_arena = self.chunk_arena_state.promote(ally);
    const chunk_ally = chunk_arena.allocator();
    self.sparse_chunk_grid.ensureTotalCapacity(ally, dims[0] * dims[1] * dims[2]);
    // TODO: u32 might be too small
    var y: u32 = 0;
    var i: usize = undefined;
    try self.chunk_data.append(chunk_ally, undefined);
    // TODO: multithread this because yes
    while(y < dims[1]) {
        defer y += 1;

        // for each y-row, we preallocate space for the entire row so no pausing during middle
        try self.chunk_data.ensureUnusedCapacity(chunk_ally, dims[0] * dims[2]);
        i = self.chunk_data.addOneAssumeCapacity();
        const slice = self.chunk_data.slice();

        // I'm pretty sure this is safe because we ensureUnusedCapacity beforehand but this should be tested
        const material_slice = slice.items(.block_materials).ptr;
        const bitmap_slice = slice.items(.block_bitmap).ptr;
        bitmap_slice[i] = .initEmpty();
        var z: u32 = 0;
        while(z < dims[2]) {
            defer z += 1;

            var x: u32 = 0;
            while(x < dims[0]) {
                defer x += 1;

                if(chunk_populator(&material_slice[i], &bitmap_slice[i], x, y, z, userpointer) == null) {
                    self.sparse_chunk_grid.appendAssumeCapacity(0);
                    continue;
                }
                if(x != 0) {
                    const prev_bitmap_position = self.sparse_chunk_grid[(x-1) + z * dims[2] + y * dims[1] * dims[1]];
                    std.debug.assert(i - prev_bitmap_position == 1 or prev_bitmap_position == 0); // this assertion should be removed if this is turned into a general purpose function
                    if(prev_bitmap_position != 0) canonicalize_x_bitmap(&bitmap_slice[prev_bitmap_position], &bitmap_slice[i]);
                }
                if(z != 0) {
                    const one_less_z_position = self.sparse_chunk_grid[x + (z-1) * dims[2] + y * dims[1] * dims[1]];
                    if(one_less_z_position != 0) canonicalize_z_bitmap(&bitmap_slice[one_less_z_position], &bitmap_slice[i]);
                }
                if(y != 0) {
                    const one_less_y_position = self.sparse_chunk_grid[x + z * dims[2] + (y - 1) * dims[1] * dims[1]];
                    if(one_less_y_position != 0) canonicalize_y_bitmap(&bitmap_slice[one_less_y_position], &bitmap_slice[i]);
                }
                self.sparse_chunk_grid.appendAssumeCapacity(@intCast(i));
                i = self.chunk_data.addOneAssumeCapacity();
                bitmap_slice[i] = .initEmpty();
            }
        }
    }
}

// call with *const array_bitset
fn extractRange(array_bitset: anytype, start_index: usize, comptime len: comptime_int) std.meta.Int(.unsigned, len) {
    if(start_index + len >= array_bitset.capacity()) unreachable; // attempting would go out of bounds

    const mask_len = @bitSizeOf(@TypeOf(array_bitset.*).MaskInt);
    var tmp: std.meta.Int(.unsigned, len) = 0;
    var i: usize = 0;
    const init_can_take = mask_len - (start_index % mask_len);
    tmp = maybe_truncate(std.meta.Int(.unsigned, len), array_bitset.masks[start_index / mask_len] >> @intCast(start_index % mask_len));
    i += init_can_take;
    while(i < len) {
        defer i += mask_len;
        tmp |= @truncate(@as(std.meta.Int(.unsigned, (len / mask_len + 1) * mask_len), array_bitset.masks[(start_index + i) / mask_len]) << @intCast(i));
    }
    return tmp;
}
// call with *const array_bitset
fn insertRange(array_bitset: anytype, start_index: usize, comptime len: comptime_int, value: std.meta.Int(.unsigned, len)) void {
    if(start_index + len >= array_bitset.capacity()) unreachable; // attempting would go out of bounds
    const MaskInt = @TypeOf(array_bitset.*).MaskInt;
    const mask_len = @bitSizeOf(MaskInt);
    var i: usize = 0;
    const start_offset: std.math.Log2Int(MaskInt) = @intCast(start_index % mask_len);
    // take is the distance to the end of the chunk
    const take: usize = @as(usize, @min(mask_len - 1 - start_offset , len - 1)) + 1;
    array_bitset.masks[start_index / mask_len] &= ~(set_first_n(MaskInt, take) << start_offset);
    array_bitset.masks[start_index / mask_len] |= maybe_truncate(MaskInt, value) << start_offset;
    i += take;
    while(mask_len + i <= len) {
        defer i += mask_len;
        array_bitset.masks[(start_index + i) / mask_len] = maybe_truncate(MaskInt, value >> @intCast(i));
    }
    array_bitset.masks[(start_index + i) / mask_len] &= ~set_first_n(MaskInt, len - i);
    array_bitset.masks[(start_index + i) / mask_len] |= @intCast(@as(std.meta.Int(.unsigned, (len / mask_len + 1) * mask_len), value) >> @intCast(i));
}

fn set_first_n(comptime T: type, n: usize) T {
    if(n >= @bitSizeOf(T)) return ~@as(T, 0);
    return (@as(T, 1) << @intCast(n)) - 1;
}

fn maybe_truncate(comptime DestT: type, val: anytype) DestT {
    if(@bitSizeOf(@TypeOf(val)) < @bitSizeOf(DestT)) return val;
    return @truncate(val);
}

// TODO: test this rigourously because my code is "optimized" dogcrap
// TODO: don't rely on codegen of big ints because apparently zig is bad at those
test {
    var test_bitset: std.bit_set.ArrayBitSet(usize, 400) = .initFull();
    test_bitset.setRangeValue(.{.start = 100, .end = 110}, false);
    test_bitset.setRangeValue(.{.start = 63, .end = 66}, false);
    test_bitset.setRangeValue(.{.start = 150, .end = 350}, false);
    try std.testing.expectEqual(0b11111_00000_00000_11111, extractRange(&test_bitset, 95, 20));
    try std.testing.expectEqual(0b11111_00011, extractRange(&test_bitset, 61, 10));
    try std.testing.expectEqual(0b01111_11111 + (0b1 << (350-141)), extractRange(&test_bitset, 141, (350-141+1)));

    test_bitset = .initFull();
    insertRange(&test_bitset, 100, 100, 0b001100);
    try std.testing.expectEqual(0b00001100 + (1 << 100), extractRange(&test_bitset, 100, 101));
    test_bitset = .initFull();
    insertRange(&test_bitset, 0, 64, 0x7F00_FF00_FF00_00FF);
    try std.testing.expectEqual(0x1_7F00_FF00_FF00_00FF, extractRange(&test_bitset, 0, 65));
}
/// left should be the lower x value
pub fn canonicalize_x_bitmap(left: *Chunk.BlockBitmap, right: *Chunk.BlockBitmap) void {
    var y: usize = 1;
    while(y < Chunk.CHUNK_SIZE_WITH_ADJ - 1) {
        defer y += 1;

        var z: usize = 1;
        while(z < Chunk.CHUNK_SIZE_WITH_ADJ - 1) {
            defer z += 1;

            const offset = z * Chunk.CHUNK_SIZE_WITH_ADJ + y * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ;

            const x_from_left = Chunk.CHUNK_SIZE_WITH_ADJ - 2;
            const x_to_left = x_from_left + 1;
            const x_from_right = 1;
            const x_to_right = x_from_right - 1;
            right.setValue(x_to_right + offset, left.isSet(x_from_left + offset));
            left.setValue(x_to_left + offset, right.isSet(x_from_right + offset));
        }
    }
}

/// left should be the lower z value
pub fn canonicalize_z_bitmap(left: *Chunk.BlockBitmap, right: *Chunk.BlockBitmap) void {

    var y: usize = 1;
    while(y < Chunk.CHUNK_SIZE_WITH_ADJ - 1) {
        defer y += 1;

        const z_from_left = Chunk.CHUNK_SIZE_WITH_ADJ - 2;
        const z_to_left = z_from_left + 1;
        const z_from_right = 1;
        const z_to_right = z_from_right - 1;

        const right_offset = 1 + y * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ;
        const left_offset = 1 + y * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ;
        insertRange(right, z_to_right * Chunk.CHUNK_SIZE_WITH_ADJ + right_offset, Chunk.CHUNK_SIZE, extractRange(left, z_from_left * Chunk.CHUNK_SIZE_WITH_ADJ + left_offset, Chunk.CHUNK_SIZE));
        insertRange(left, z_to_left * Chunk.CHUNK_SIZE_WITH_ADJ + left_offset, Chunk.CHUNK_SIZE, extractRange(right, z_from_right * Chunk.CHUNK_SIZE_WITH_ADJ + right_offset, Chunk.CHUNK_SIZE));
    }
}

pub fn canonicalize_y_bitmap(bot: *Chunk.BlockBitmap, top: *Chunk.BlockBitmap) void {
    const y_from_bot = Chunk.CHUNK_SIZE_WITH_ADJ - 2;
    const y_to_bot = y_from_bot + 1;
    const y_from_top = 1;
    const y_to_top = y_from_top - 1;
    const CHUNK_ADJ_SQUARED = Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ;
    insertRange(top, y_to_top * CHUNK_ADJ_SQUARED, CHUNK_ADJ_SQUARED, extractRange(bot, y_from_bot * CHUNK_ADJ_SQUARED, CHUNK_ADJ_SQUARED));
    insertRange(bot, y_to_bot * CHUNK_ADJ_SQUARED, CHUNK_ADJ_SQUARED, extractRange(top, y_from_top * CHUNK_ADJ_SQUARED, CHUNK_ADJ_SQUARED));
}

// this test sets various points along the z shared by 2 bitmaps, canonicalizes the edges, and then tests if the points were copied correctly
test canonicalize_z_bitmap {
    var left: Chunk.BlockBitmap = .initEmpty();
    var right: Chunk.BlockBitmap = .initEmpty();
    const left_coords = .{
        .{0, 0},
        .{0, Chunk.CHUNK_SIZE - 1},
        .{Chunk.CHUNK_SIZE - 1, 0},
        .{Chunk.CHUNK_SIZE - 1, Chunk.CHUNK_SIZE - 1},
        .{3, 3},
    };
    const right_coords = .{
        .{0, Chunk.CHUNK_SIZE / 2},
        .{Chunk.CHUNK_SIZE / 2, 0},
        .{Chunk.CHUNK_SIZE - 1, Chunk.CHUNK_SIZE / 2},
        .{Chunk.CHUNK_SIZE / 2, Chunk.CHUNK_SIZE - 1},
        .{5, 5}
    };
    inline for(left_coords, right_coords) |left_coord, right_coord| {
        left.set((left_coord[0] + 1) + (Chunk.CHUNK_SIZE_WITH_ADJ - 2) * Chunk.CHUNK_SIZE_WITH_ADJ + (left_coord[1] + 1) * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ);
        right.set((right_coord[0] + 1) + 1 * Chunk.CHUNK_SIZE_WITH_ADJ + (right_coord[1] + 1) * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ);
    }
    canonicalize_z_bitmap(&left, &right);

    inline for(left_coords, right_coords) |left_coord, right_coord| {
        // check right for lefts
        {
            const index = (left_coord[0] + 1) + 0 * Chunk.CHUNK_SIZE_WITH_ADJ + (left_coord[1] + 1) * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ;
            try std.testing.expect(right.isSet(index));
            right.unset(index);
        }
        // check left for rights
        {
            const index = (right_coord[0] + 1) + (Chunk.CHUNK_SIZE_WITH_ADJ - 1) * Chunk.CHUNK_SIZE_WITH_ADJ + (right_coord[1] + 1) * Chunk.CHUNK_SIZE_WITH_ADJ * Chunk.CHUNK_SIZE_WITH_ADJ;
            try std.testing.expect(left.isSet(index));
            left.unset(index);
        }
    }
    try std.testing.expectEqual(5, left.count());
    try std.testing.expectEqual(5, right.count());
}


/// Blocks are organized in x, z, y order
/// The real stored size is 1 block bigger on all edges to keep track of adjacent chunks edge blocks
pub const Chunk = struct {
    pub const CHUNK_SIZE: comptime_int = 16;
    pub const CHUNK_SIZE_WITH_ADJ: comptime_int = CHUNK_SIZE + 2;
    const SideInt = std.math.IntFittingRange(0, CHUNK_SIZE - 1);
    const SideAndAdjInt = std.math.IntFittingRange(0, CHUNK_SIZE_WITH_ADJ - 1);
    const MaterialInt = std.math.IntFittingRange(0, CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE - 1); // TODO: rename
    const BitmapInt = std.math.IntFittingRange(0, CHUNK_SIZE_WITH_ADJ * CHUNK_SIZE_WITH_ADJ * CHUNK_SIZE_WITH_ADJ - 1);

    comptime {
        // we heavily rely on this fact to be able to tightly pack the data. If this is changed, redo this code
        std.debug.assert(std.math.IntFittingRange(0, CHUNK_SIZE - 1) == u4);
        std.debug.assert(MaterialIndex == u16);
    }
    pub const Face = packed struct(u32) {
        /// laid out in such a way such that bottom bit corresponds to being low or high on the axis
        pub const Direction = enum(u3) {
            east = 0b000,
            west = 0b001,
            south = 0b010,
            north = 0b011,
            bottom = 0b100,
            top = 0b101,
        };
        x: u4,
        y: u4,
        z: u4,
        face: Direction,
        __padding: u1,            
        material: u16, // TODO: use palette compression per chunk, no need to use the full u16 index
    };

    pub fn material_index(x: SideInt, y: SideInt, z: SideInt) MaterialInt {
        std.debug.assert(x < CHUNK_SIZE and y < CHUNK_SIZE and z < CHUNK_SIZE);
        return @as(MaterialInt, x) + @as(MaterialInt, z) * CHUNK_SIZE + @as(MaterialInt, y) * CHUNK_SIZE * CHUNK_SIZE;
    }
    
    const BlockMaterials = [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]MaterialIndex;
    const BlockBitmap = std.bit_set.ArrayBitSet(usize, CHUNK_SIZE_WITH_ADJ * CHUNK_SIZE_WITH_ADJ * CHUNK_SIZE_WITH_ADJ); // TODO: use an array of usize, add padding so each y row starts at byte offset

    block_materials: BlockMaterials,
    block_bitmap: BlockBitmap,
    mesh: std.ArrayListUnmanaged(Face),


    /// sets a block according to its position in the actual world
    /// returns whether the entire block can be cleaned up
    pub fn setblock(block_materials: *BlockMaterials, block_bitmap: *BlockBitmap, index: MaterialInt, material: MaterialIndex) bool {
        block_materials[index.val] = material;
        block_bitmap.setValue(index, material != 0);
        if(block_bitmap.count() == 0) {
            @branchHint(.unlikely);
            return true;
        }
        return false;
    }
};