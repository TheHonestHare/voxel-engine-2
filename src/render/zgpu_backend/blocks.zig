const std = @import("std");
const zgpu = @import("zgpu");
const World = @import("../../BlockWorld.zig");
const render = @import("render.zig");
const util = @import("../../util.zig");

pub const INDEX_PER_FACE = 6;
const SPARE_CHUNKS = 10;

pub const State = struct {
    constants: struct {
        chunk_data_single_inst_size: usize,
    },
    pipeline: zgpu.RenderPipelineHandle,
    index_buffer_h: zgpu.BufferHandle,
    face_data_buffer_h: zgpu.BufferHandle,
    chunk_data_buffer_h: zgpu.BufferHandle,
    textures_buffer_h: zgpu.BufferHandle,
    bindgroup_h: zgpu.BindGroupHandle,
    world: *const World,
};

// TODO: ensure max_required_faces is multiple of minStorageBufferOffsetAlignment
// TODO: if this function fails should auto-deinit everything
pub fn init(gctx: *zgpu.GraphicsContext, base_bindgroup_layouts: render.BindGroups, world: *const World) !State {
    var limits: zgpu.wgpu.SupportedLimits = .{};
    _ = gctx.device.getLimits(&limits); // TODO: why are we discarding here?
    const min_align_storage = limits.limits.min_storage_buffer_offset_alignment;
    const min_faces_buffer_size = util.roundUp(@as(usize, @sizeOf([World.Chunk.MAX_REQUIRED_FACES]World.Chunk.Face)), min_align_storage);
    const index_buffer_h = gctx.createBuffer(.{
        .label = "Block index buffer",
        .mapped_at_creation = true,
        .size = @sizeOf(u16) * INDEX_PER_FACE * World.Chunk.MAX_REQUIRED_FACES,
        .usage = .{ .index = true },
    });
    // populate an index buffer with indices that will draw quads
    {
        const index_buffer = gctx.lookupResource(index_buffer_h) orelse return error.ResourceCreationFailure;
        const mapped_index_buffer = index_buffer.getMappedRange([INDEX_PER_FACE]u16, 0, World.Chunk.MAX_REQUIRED_FACES).?;
        for (mapped_index_buffer, 0..) |*indices, i_usize| {
            const i: u16 = @intCast(i_usize);
            indices.* = .{
                0 + 4 * i,
                1 + 4 * i,
                2 + 4 * i,
                2 + 4 * i,
                1 + 4 * i,
                3 + 4 * i,
            };
        }
        index_buffer.unmap();
    }

    const chunk_count = world.chunk_data.len - 1;

    const face_data_buffer_h = gctx.createBuffer(.{
        .label = "Block face data",
        .mapped_at_creation = true,
        .size = min_faces_buffer_size * chunk_count,
        .usage = .{
            .storage = true,
        },
    });

    // populate the face data buffer with all data
    {
        const face_data_buffer = gctx.lookupResource(face_data_buffer_h) orelse return error.ResourceCreationFailure;
        const max_faces_and_padding = util.roundUp(World.Chunk.MAX_REQUIRED_FACES, min_align_storage / @sizeOf(World.Chunk.Face));
        const mapped_face_buffer = face_data_buffer.getMappedRange(World.Chunk.Face, 0, min_faces_buffer_size * chunk_count / @sizeOf(World.Chunk.Face)).?;

        for (world.chunk_data.items(.mesh)[1..], 0..) |mesh, i| {
            std.debug.assert(mesh.len <= World.Chunk.MAX_REQUIRED_FACES);
            @memcpy(mapped_face_buffer[i * max_faces_and_padding .. i * max_faces_and_padding + World.Chunk.MAX_REQUIRED_FACES].ptr, mesh);
        }
        face_data_buffer.unmap();
    }

    const ChunkCoords = [3]u32;

    const chunk_data_single_inst_size = util.roundUp(@sizeOf(ChunkCoords), min_align_storage);

    const chunk_data_buffer_h = gctx.createBuffer(.{
        .label = "Chunk coordinate buffer",
        .mapped_at_creation = true,
        .size = chunk_data_single_inst_size * chunk_count,
        .usage = .{
            .storage = true,
        },
    });

    // populate the chunk data buffer with coordinates for each chunk
    {
        const chunk_data_buffer = gctx.lookupResource(chunk_data_buffer_h) orelse return error.ResourceCreationFailure;
        const mapped_buffer = chunk_data_buffer.getMappedRange(u32, 0, chunk_data_single_inst_size * chunk_count / @sizeOf(u32)).?;

        var curr_offset: usize = 0;
        for (world.chunk_data.items(.chunk_coords)[1..]) |chunk_coord| {
            @memcpy(mapped_buffer[curr_offset .. curr_offset + 3], &chunk_coord);
            curr_offset += chunk_data_single_inst_size / @sizeOf(u32);
        }
        chunk_data_buffer.unmap();
    }

    const textures_buffer_h = gctx.createBuffer(.{
        .label = "Material's pixel's buffer",
        .mapped_at_creation = true,
        .size = @sizeOf(World.ImageTexture) * world.textures.len,
        .usage = .{
            .storage = true,
        },
    });

    {
        const textures_buffer = gctx.lookupResource(textures_buffer_h) orelse return error.ResourceCreationFailure;
        const mapped_buffer = textures_buffer.getMappedRange(World.ImageTexture, 0, world.textures.len).?;
        @memcpy(mapped_buffer, world.textures);
        textures_buffer.unmap();
    }

    const bindgroup_layout_h = gctx.createBindGroupLayout(&.{
        zgpu.bufferEntry(0, .{ .vertex = true }, .read_only_storage, true, 0),
        zgpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, true, 0),
        zgpu.bufferEntry(2, .{ .fragment = true }, .read_only_storage, false, 0),
    });
    defer gctx.releaseResource(bindgroup_layout_h);

    const bindgroup_h = gctx.createBindGroup(bindgroup_layout_h, &.{
        .{
            .binding = 0,
            .buffer_handle = face_data_buffer_h,
            .size = @sizeOf([World.Chunk.MAX_REQUIRED_FACES]World.Chunk.Face),
        },
        .{
            .binding = 1,
            .buffer_handle = chunk_data_buffer_h,
            .size = chunk_data_single_inst_size,
        },
        .{
            .binding = 2,
            .buffer_handle = textures_buffer_h,
            .size = @sizeOf(World.ImageTexture) * world.textures.len,
        },
    });
    const render_pipeline_h = blk: {
        const pipeline_layout_h = gctx.createPipelineLayout(&.{ base_bindgroup_layouts.layouts[0], base_bindgroup_layouts.layouts[1], bindgroup_layout_h });
        defer gctx.releaseResource(pipeline_layout_h);

        const vs = zgpu.createWgslShaderModule(gctx.device, std.fmt.comptimePrint("const max_face_count = {d};", .{World.Chunk.MAX_REQUIRED_FACES}) ++ @embedFile("block_vs.wgsl"), "vertex shader");
        defer vs.release();
        const fs = zgpu.createWgslShaderModule(gctx.device, @embedFile("block_fs.wgsl"), "fragment shader");
        defer fs.release();

        const colour_targets = [_]zgpu.wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
        }};

        const pipeline_desc = zgpu.wgpu.RenderPipelineDescriptor{ .vertex = .{ .module = vs, .entry_point = "main" }, .primitive = .{
            .cull_mode = .back,
            .front_face = .ccw,
            .topology = .triangle_list,
        }, .fragment = &.{
            .module = fs,
            .entry_point = "main",
            .target_count = colour_targets.len,
            .targets = &colour_targets,
        }, .depth_stencil = &.{
            .format = .depth32_float,
            .depth_compare = .less,
            .depth_write_enabled = true,
        } };
        break :blk gctx.createRenderPipeline(pipeline_layout_h, pipeline_desc);
    };
    return .{
        .constants = .{
            .chunk_data_single_inst_size = chunk_data_single_inst_size,
        },
        .world = world,
        .pipeline = render_pipeline_h,
        .index_buffer_h = index_buffer_h,
        .face_data_buffer_h = face_data_buffer_h,
        .chunk_data_buffer_h = chunk_data_buffer_h,
        .textures_buffer_h = textures_buffer_h,
        .bindgroup_h = bindgroup_h,
    };
}

pub fn draw(state: State, gctx: *zgpu.GraphicsContext, pass: zgpu.wgpu.RenderPassEncoder) !void {
    const pipeline = gctx.lookupResource(state.pipeline) orelse return error.FailedLookup;
    const index_buffer = gctx.lookupResource(state.index_buffer_h) orelse return error.FailedLookup;
    const bindgroup = gctx.lookupResource(state.bindgroup_h) orelse return error.FailedLookup;

    pass.setIndexBuffer(index_buffer, .uint16, 0, @sizeOf(u16) * INDEX_PER_FACE * World.Chunk.MAX_REQUIRED_FACES); // TODO: check if size is per elem or per byte
    pass.setPipeline(pipeline);

    // TODO: draw multiple chunks

    const mesh_slice = state.world.chunk_data.items(.mesh)[1..];

    for (0..state.world.chunk_data.len - 1) |i| {
        const face_dyn_offset = i * @sizeOf(World.Chunk.Face) * World.Chunk.MAX_REQUIRED_FACES;
        const chunk_data_dyn_offset = i * state.constants.chunk_data_single_inst_size;

        pass.setBindGroup(2, bindgroup, &.{ @intCast(face_dyn_offset), @intCast(chunk_data_dyn_offset) });
        pass.drawIndexed(@intCast(mesh_slice[i].len * INDEX_PER_FACE), 1, 0, 0, 0);
    }
}
