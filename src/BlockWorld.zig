const std = @import("std");

pub const TextureIndex = u16;
pub const MaterialIndex = u16;
pub const ChunkPopulatorFn = *const fn (
    *Chunk.BlockMaterials,
    x: u32,
    y: u32,
    z: u32,
    userpointer: *anyopaque,
) ?void;

const BlockWorld = @This();

ally: std.mem.Allocator,
chunk_arena: std.heap.ArenaAllocator, // TODO: don't use an arena since we don't clear frequently
dims: [3]u16,
/// indexes into the chunk_data grid, 0 meaning empty
sparse_chunk_grid: []u32,
/// first element is always garbage and empty
chunk_data: std.MultiArrayList(Chunk),
textures: []const ImageTexture,
material_textures: []const [6]TextureIndex,

/// chunk_populator should set the bitmask to 0 first
/// chunk_populator should return null if the chunk is unempty
pub fn init(ally: std.mem.Allocator, dims: [3]u16, userpointer: *anyopaque, chunk_populator: ChunkPopulatorFn, textures: []const ImageTexture, material_textures: []const [6]TextureIndex) !@This() {
    std.debug.assert(textures.len < std.math.maxInt(TextureIndex));
    std.debug.assert(material_textures.len < std.math.maxInt(MaterialIndex));
    var self: @This() = .{
        .ally = ally,
        .chunk_arena = .init(ally),
        .dims = dims,
        .sparse_chunk_grid = undefined,
        .chunk_data = .{},
        .textures = textures, // TODO: make copy or no?
        .material_textures = material_textures, // TODO: make copy or no?
    };
    errdefer self.chunk_arena.deinit();
    const chunk_ally = self.chunk_arena.allocator();

    self.sparse_chunk_grid = try ally.alloc(u32, dims[0] * dims[1] * dims[2]);
    errdefer ally.free(self.sparse_chunk_grid);

    var y: u16 = 0;
    var i: usize = undefined;
    try self.chunk_data.append(chunk_ally, .{ .block_materials = undefined, .mesh = &.{}, .chunk_coords = undefined });
    // TODO: multithread this because yes
    while (y < dims[1]) {
        defer y += 1;

        // for each y-row, we preallocate space for the entire row so no pausing during middle
        try self.chunk_data.ensureUnusedCapacity(chunk_ally, dims[0] * dims[2]);
        i = self.chunk_data.addOneAssumeCapacity();
        const slice = self.chunk_data.slice();

        // I'm pretty sure this is safe because we ensureUnusedCapacity beforehand but this should be tested
        const material_slice = slice.items(.block_materials).ptr;
        const mesh_slice = slice.items(.mesh).ptr;
        _ = mesh_slice; // autofix
        const chunk_coords_slice = slice.items(.chunk_coords).ptr;
        var z: u16 = 0;
        while (z < dims[2]) {
            defer z += 1;

            var x: u16 = 0;
            while (x < dims[0]) {
                defer x += 1;

                if (chunk_populator(&material_slice[i], x, y, z, userpointer) == null) {
                    self.sparse_chunk_grid[self.index_into_sparse(.{ x, y, z })] = 0;
                    continue;
                }
                self.sparse_chunk_grid[self.index_into_sparse(.{ x, y, z })] = @intCast(i);
                // mesh will be computed later
                chunk_coords_slice[i] = .{ x, y, z };

                i = self.chunk_data.addOneAssumeCapacity();
            }
        }
        self.chunk_data.len -= 1;
    }

    // mesh generation
    // TODO: use a memory pool
    // TODO: move to different thread
    const slice = self.chunk_data.slice();
    const mesh_slice = slice.items(.mesh).ptr;
    y = 0;
    while (y < dims[1]) {
        defer y += 1;
        var z: u16 = 0;
        while (z < dims[2]) {
            defer z += 1;
            var x: u16 = 0;
            while (x < dims[0]) {
                defer x += 1;
                const dense_index = self.index_into_dense(.{ x, y, z });
                if (dense_index == 0) continue;

                const chunk_memory = try chunk_ally.alloc(Chunk.Face, Chunk.MAX_REQUIRED_FACES);
                const generated_faces_count = Chunk.generateCulledMesh(@ptrCast(chunk_memory), self, .{ x, y, z });
                if (generated_faces_count == 0) {
                    chunk_ally.free(chunk_memory);
                    continue;
                }
                mesh_slice[dense_index] = chunk_memory[0..generated_faces_count];
            }
        }
    }
    return self;
}

pub fn deinit(self: *@This()) void {
    self.chunk_arena.deinit();
    self.ally.free(self.sparse_chunk_grid);
}

/// get the index into the sparse array from coordinates
pub fn index_into_sparse(self: *const @This(), coords: [3]u16) usize {
    return coords[1] * self.dims[1] * self.dims[1] + coords[2] * self.dims[2] + coords[0];
}

/// get the index into the dense array from coordinates
pub fn index_into_dense(self: *const @This(), coords: [3]u16) u32 {
    return self.sparse_chunk_grid[self.index_into_sparse(coords)];
}

pub const ImageTexture = [8][8]ColourUnorm;

pub const ColourUnorm = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    _padding: u8 = undefined,
};

pub const Chunk = struct {
    pub const CHUNK_SIZE = 16;
    pub const CHUNK_SIZE_EDGES = CHUNK_SIZE + 2;
    // obtained from a chunk with every alternating block removed
    pub const MAX_REQUIRED_FACES = (CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE / 2) * 6;
    const SideInt = std.math.IntFittingRange(0, CHUNK_SIZE - 1);
    const SideAndAdjInt = std.math.IntFittingRange(0, CHUNK_SIZE_EDGES - 1);
    const MaterialInt = std.math.IntFittingRange(0, CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE - 1); // TODO: rename

    comptime {
        // we heavily rely on this fact to be able to tightly pack the data. If this is changed, redo this code
        std.debug.assert(std.math.IntFittingRange(0, CHUNK_SIZE - 1) == u4);
        std.debug.assert(TextureIndex == u16);
    }
    pub const Face = packed struct(u32) {
        /// laid out in such a way such that bottom bit corresponds to being low or high on the axis
        pub const Direction = enum(u3) {
            west = 0b000,
            east = 0b001,
            south = 0b010,
            north = 0b011,
            bottom = 0b100,
            top = 0b101,
        };
        x: u4,
        y: u4,
        z: u4,
        face: Direction,
        __padding: u1 = undefined,
        material: TextureIndex, // TODO: use palette compression per chunk, no need to use the full u16 index
    };

    pub fn material_index(x: SideInt, y: SideInt, z: SideInt) MaterialInt {
        std.debug.assert(x < CHUNK_SIZE and y < CHUNK_SIZE and z < CHUNK_SIZE);
        return @as(MaterialInt, x) + @as(MaterialInt, z) * CHUNK_SIZE + @as(MaterialInt, y) * CHUNK_SIZE * CHUNK_SIZE;
    }

    pub const BlockMaterials = [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]MaterialIndex;

    block_materials: BlockMaterials,
    /// allocated with world allocator
    mesh: []Face,
    chunk_coords: [3]u32,

    pub fn generateCulledMesh(result: *[MAX_REQUIRED_FACES]Face, world: BlockWorld, coordinates: [3]u16) usize {

        // ensure that the bitsets are big enough
        comptime std.debug.assert(CHUNK_SIZE_EDGES < @bitSizeOf(u32));

        const material_slice = world.chunk_data.items(.block_materials);

        const current_chunk_index = world.index_into_dense(coordinates);
        if (current_chunk_index == 0) return 0;
        const current_chunk = material_slice[current_chunk_index];

        const prev_x_chunk_index = if (coordinates[0] == 0) 0 else world.index_into_dense(.{ coordinates[0] - 1, coordinates[1], coordinates[2] });
        const prev_x_chunk = if (prev_x_chunk_index == 0) undefined else material_slice[prev_x_chunk_index];

        const prev_y_chunk_index = if (coordinates[1] == 0) 0 else world.index_into_dense(.{ coordinates[0], coordinates[1] - 1, coordinates[2] });
        const prev_y_chunk = if (prev_y_chunk_index == 0) undefined else material_slice[prev_y_chunk_index];

        const prev_z_chunk_index = if (coordinates[2] == 0) 0 else world.index_into_dense(.{ coordinates[0], coordinates[1], coordinates[2] - 1 });
        const prev_z_chunk = if (prev_z_chunk_index == 0) undefined else material_slice[prev_z_chunk_index];

        const next_x_chunk_index = if (coordinates[0] + 1 >= world.dims[0]) 0 else world.index_into_dense(.{ coordinates[0] + 1, coordinates[1], coordinates[2] });
        const next_x_chunk = if (next_x_chunk_index == 0) undefined else material_slice[next_x_chunk_index];

        const next_y_chunk_index = if (coordinates[1] + 1 >= world.dims[1]) 0 else world.index_into_dense(.{ coordinates[0], coordinates[1] + 1, coordinates[2] });
        const next_y_chunk = if (next_y_chunk_index == 0) undefined else material_slice[next_y_chunk_index];

        const next_z_chunk_index = if (coordinates[2] + 1 >= world.dims[2]) 0 else world.index_into_dense(.{ coordinates[0], coordinates[1], coordinates[2] + 1 });
        const next_z_chunk = if (next_z_chunk_index == 0) undefined else material_slice[next_z_chunk_index];

        // initialize the bitmaps
        var bitmaps: [CHUNK_SIZE_EDGES][CHUNK_SIZE_EDGES]u32 = @splat(@splat(0));
        for (0..CHUNK_SIZE) |chunk_y| {
            const bitmap_y = chunk_y + 1;
            for (0..CHUNK_SIZE) |chunk_z| {
                const bitmap_z = chunk_z + 1;
                bitmaps[bitmap_y][bitmap_z] = extract_x_row(current_chunk[chunk_y * CHUNK_SIZE * CHUNK_SIZE + chunk_z * CHUNK_SIZE ..][0..CHUNK_SIZE].*);
            }
        }

        // fill in padding along y direction
        if (prev_y_chunk_index != 0) {
            for (0..CHUNK_SIZE) |z| {
                bitmaps[0][z + 1] = extract_x_row(prev_y_chunk[(CHUNK_SIZE - 1) * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE ..][0..CHUNK_SIZE].*);
            }
        }
        if (next_y_chunk_index != 0) {
            for (0..CHUNK_SIZE) |z| {
                bitmaps[CHUNK_SIZE_EDGES - 1][z + 1] = extract_x_row(next_y_chunk[0 * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE ..][0..CHUNK_SIZE].*);
            }
        }

        // fill in padding along z direction
        if (prev_z_chunk_index != 0) {
            for (0..CHUNK_SIZE) |y| {
                bitmaps[y + 1][0] = extract_x_row(prev_z_chunk[y * CHUNK_SIZE * CHUNK_SIZE + (CHUNK_SIZE - 1) * CHUNK_SIZE ..][0..CHUNK_SIZE].*);
            }
        }
        if (next_z_chunk_index != 0) {
            for (0..CHUNK_SIZE) |y| {
                bitmaps[y + 1][CHUNK_SIZE_EDGES - 1] = extract_x_row(next_z_chunk[y * CHUNK_SIZE * CHUNK_SIZE + 0 * CHUNK_SIZE ..][0..CHUNK_SIZE].*);
            }
        }

        // fill in the padding along x direction
        if (prev_x_chunk_index != 0) {
            for (0..CHUNK_SIZE) |y| {
                for (0..CHUNK_SIZE) |z| {
                    bitmaps[y + 1][z + 1] |= @intFromBool(prev_x_chunk[y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + (CHUNK_SIZE - 1)] > 0);
                }
            }
        }
        if (next_x_chunk_index != 0) {
            for (0..CHUNK_SIZE) |y| {
                for (0..CHUNK_SIZE) |z| {
                    bitmaps[y + 1][z + 1] |= @as(u32, @intFromBool(next_x_chunk[y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + (0)] > 0)) << (CHUNK_SIZE_EDGES - 1);
                }
            }
        }
        // Now we must take the bitmaps and generate faces wherever we need to. For the x direction, bitshifting 1 left and xor-ing with
        // the original allows us to find all the locations in which the original bitmap changed from 0 to 1 or vice versa. These locations
        // are where we must generate a face.
        // By and-ing switch_locations with the original, we get all the places in which the original changed from 1 to 0 and an
        // west face should be generated. Then, we can take the remaining 1's from the switch_locations bitmap, and these are where
        // it changed from a 0 to a 1. By bitshifting this one right, we can find the locations we must generate an east face.
        // Finally, we bitshift right by 1 and truncate to get rid of the padding

        comptime std.debug.assert(CHUNK_SIZE == @bitSizeOf(u16));
        // mesh all x direction faces
        var east_faces: [CHUNK_SIZE][CHUNK_SIZE]u16 = undefined;
        var west_faces: [CHUNK_SIZE][CHUNK_SIZE]u16 = undefined;

        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                const x_row = bitmaps[y + 1][z + 1];
                const switch_locations = x_row ^ (x_row << 1);
                const west_faces_in_row = x_row & switch_locations;
                const east_faces_in_row = ((~west_faces_in_row) & switch_locations) >> 1;
                east_faces[y][z], west_faces[y][z] = .{ @truncate(east_faces_in_row >> 1), @truncate(west_faces_in_row >> 1) };
            }
        }

        // y direction and z direction use a similar algorithm, but switch_locations can instead be found by
        // xor-ing two rows together. We also have to special case the padding rows at the ends of the y and z
        // directions

        // z direction
        var north_faces: [CHUNK_SIZE][CHUNK_SIZE]u16 = undefined;
        var south_faces: [CHUNK_SIZE][CHUNK_SIZE]u16 = undefined;
        for (0..CHUNK_SIZE) |y| {
            var x_row = bitmaps[y + 1][0];
            for (0..CHUNK_SIZE_EDGES - 1) |real_z| {
                const next_x_row = bitmaps[y + 1][real_z + 1];
                const switch_locations = x_row ^ next_x_row;

                if (real_z != 0) {
                    const north_faces_in_row = x_row & switch_locations;
                    north_faces[y][real_z - 1] = @truncate(north_faces_in_row >> 1);
                }
                if (real_z != CHUNK_SIZE_EDGES - 2) {
                    const south_faces_in_row = (~x_row) & switch_locations;
                    south_faces[y][real_z] = @truncate(south_faces_in_row >> 1);
                }
                x_row = next_x_row;
            }
        }

        // y direction
        var top_faces: [CHUNK_SIZE][CHUNK_SIZE]u16 = undefined;
        var bottom_faces: [CHUNK_SIZE][CHUNK_SIZE]u16 = undefined;
        for (0..CHUNK_SIZE_EDGES - 1) |real_y| {
            for (0..CHUNK_SIZE) |z| {
                const x_row = bitmaps[real_y][z + 1];
                const next_x_row = bitmaps[real_y + 1][z + 1];
                const switch_locations = x_row ^ next_x_row;

                if (real_y != 0) {
                    const top_faces_in_row = x_row & switch_locations;
                    top_faces[real_y - 1][z] = @truncate(top_faces_in_row >> 1);
                }
                if (real_y != CHUNK_SIZE_EDGES - 2) {
                    const bottom_faces_in_row = (~x_row) & switch_locations;
                    bottom_faces[real_y][z] = @truncate(bottom_faces_in_row >> 1);
                }
            }
        }

        var face_count: usize = 0;

        for (&[6][CHUNK_SIZE][CHUNK_SIZE]u16{ west_faces, east_faces, south_faces, north_faces, bottom_faces, top_faces }, std.enums.values(Face.Direction)) |face_bitmap, dir| {
            for (0..CHUNK_SIZE) |y| {
                for (0..CHUNK_SIZE) |z| {
                    var x_row = face_bitmap[y][z];
                    var index = @ctz(x_row);
                    while (index != 16) {
                        x_row &= ~(@as(u16, 1) << @intCast(index));
                        const mat_index = current_chunk[index + z * CHUNK_SIZE + y * CHUNK_SIZE * CHUNK_SIZE];
                        std.debug.assert(mat_index != 0);
                        result[face_count] = .{
                            .x = @intCast(index),
                            .y = @intCast(y),
                            .z = @intCast(z),
                            .material = world.material_textures[mat_index - 1][@intFromEnum(dir)],
                            .face = dir,
                        };
                        face_count += 1;
                        index = @ctz(x_row);
                    }
                }
            }
        }
        return face_count;
    }
    fn extract_x_row(array: [CHUNK_SIZE]MaterialIndex) u32 {
        // TODO: dynamically get the suggested vector length
        comptime std.debug.assert(CHUNK_SIZE == @bitSizeOf(u16));
        const RowMaterialVec = @Vector(CHUNK_SIZE, u16);
        const non_empty_vec = array > @as(RowMaterialVec, @splat(0));
        return @as(u32, @as(u16, @bitCast(non_empty_vec))) << 1;
    }
};
