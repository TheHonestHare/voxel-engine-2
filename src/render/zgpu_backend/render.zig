const std = @import("std");
const builtin = @import("builtin");
const util = @import("../../util.zig");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const Camera = @import("../../Camera.zig");
const zmath = @import("zmath");

var gctx: *zgpu.GraphicsContext = undefined;
var render_pipeline_h: zgpu.RenderPipelineHandle = undefined;
var constants_bindgroup_h: zgpu.BindGroupHandle = undefined;
var constants_buffer_h: zgpu.BufferHandle = undefined;
var uniform_bindgroup_h: zgpu.BindGroupHandle = undefined;
var vertex_buffer_h: zgpu.BufferHandle = undefined;
pub var camera: Camera = undefined;

const Vertex = extern struct { pos: [2]f32 };

const VERTEX_TEST_DATA: []const Vertex = &.{
    .{ .pos = .{ -0.5, -0.5 } },
    .{ .pos = .{ 0.5, -0.5 } },
    .{ .pos = .{ 0, 0.5 } },
};

const test_vs =
    \\  @group(0) @binding(0) var<uniform> perspective_mat: mat4x4<f32>;
    \\  @group(1) @binding(0) var<uniform> camera_transform_mat: mat4x4<f32>;
    \\  @vertex fn main(@location(0) pos: vec2<f32>) -> @builtin(position) vec4<f32> {
    \\      let orig_pos = vec4f(pos, -2, 1);
    \\      return perspective_mat * camera_transform_mat * orig_pos;
    \\  }
;

const test_fs =
    \\  @fragment fn main() -> @location(0) vec4<f32> {
    \\      return vec4f(1, 1, 0, 1);
    \\  }
;

pub fn init(window: *zglfw.Window, ally: std.mem.Allocator) void {
    init_inner(window, ally) catch |e| util.exitWithError(util.init_logger, "Error initiating render pipeline: {any}", .{e});
}

fn init_inner(window: *zglfw.Window, ally: std.mem.Allocator) !void {
    gctx = try zgpu.GraphicsContext.create(
        ally,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),

            // optional fields
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{}, // default context creation options
    );
    // TODO: see if valid to only call this in debug mode (for faster exit in release)
    errdefer gctx.destroy(ally);

    camera = .test_defaults(
        .{ 0, 0, 0 },
        @as(f32, @floatFromInt(gctx.swapchain_descriptor.width)) / @as(f32, @floatFromInt(gctx.swapchain_descriptor.height)),
    );

    {
        vertex_buffer_h = gctx.createBuffer(.{ .label = "vertex buffer", .mapped_at_creation = true, .usage = .{ .vertex = true }, .size = @sizeOf(Vertex) * 3 });
        const vb = gctx.lookupResource(vertex_buffer_h) orelse return error.ResourceCreationFailure;
        const mapped_vertex_buffer_range = vb.getMappedRange(Vertex, 0, 3).?;
        @memcpy(mapped_vertex_buffer_range, VERTEX_TEST_DATA);
        vb.unmap();
    }

    // Ones in here will rarely if ever change
    const constants_bindgroup_layout = gctx.createBindGroupLayout(&.{
        // Camera projection matrix
        zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, 0),
    });
    defer gctx.releaseResource(constants_bindgroup_layout);

    const layouts = try BindGroups.init();
    defer layouts.releaseLayouts();

    const pipeline_layout = gctx.createPipelineLayout(&layouts.layouts);
    defer gctx.releaseResource(pipeline_layout);

    render_pipeline_h = blk: {
        const vs = zgpu.createWgslShaderModule(gctx.device, test_vs, "vertex shader");
        defer vs.release();
        const fs = zgpu.createWgslShaderModule(gctx.device, test_fs, "fragment shader");
        defer fs.release();

        const colour_targets = [_]zgpu.wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
        }};

        const vertex_attributes = [_]zgpu.wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        };

        const vertex_buffers = [_]zgpu.wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(Vertex),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        }};

        const pipeline_desc = zgpu.wgpu.RenderPipelineDescriptor{
            .vertex = .{ .module = vs, .entry_point = "main", .buffer_count = vertex_buffers.len, .buffers = &vertex_buffers },
            .primitive = .{
                .cull_mode = .none,
                .front_face = .ccw,
                .topology = .triangle_list,
            },

            .fragment = &.{
                .module = fs,
                .entry_point = "main",
                .target_count = colour_targets.len,
                .targets = &colour_targets,
            },
        };
        break :blk gctx.createRenderPipeline(pipeline_layout, pipeline_desc);
    };
}

const BindGroups = struct {
    layouts: [2]zgpu.BindGroupLayoutHandle,

    pub fn init() !BindGroups {

        // Ones in here will rarely if ever change
        const constants_bindgroup_layout = gctx.createBindGroupLayout(&.{
            // Camera projection matrix
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, 0),
        });

        constants_buffer_h = gctx.createBuffer(.{
            .label = "Constants buffer",
            .mapped_at_creation = true,
            .size = @sizeOf(zmath.Mat),
            .usage = .{ .vertex = true, .copy_dst = true, .uniform = true },
        });
        {
            const real_buff = gctx.lookupResource(constants_buffer_h) orelse return error.ResourceCreationFailure;
            const slice: *zmath.Mat = @ptrCast(real_buff.getMappedRange(zmath.Mat, 0, 1));
            slice.* = camera.getPerspectiveMat();
            real_buff.unmap();
        }

        constants_bindgroup_h = gctx.createBindGroup(constants_bindgroup_layout, &.{.{ .binding = 0, .buffer_handle = constants_buffer_h, .offset = 0, .size = @sizeOf(zmath.Mat) }});

        const uniforms_bindgroup_layout = gctx.createBindGroupLayout(&.{
        // Camera transform matrix
        zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0)});

        uniform_bindgroup_h = gctx.createBindGroup(uniforms_bindgroup_layout, &.{.{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(zmath.Mat) }});
        return .{ .layouts = .{ constants_bindgroup_layout, uniforms_bindgroup_layout } };
    }

    pub fn releaseLayouts(self: BindGroups) void {
        for (self.layouts) |layout| {
            gctx.releaseResource(layout);
        }
    }
};

pub fn deinit(ally: std.mem.Allocator) void {
    gctx.destroy(ally);
}

pub fn draw() void {
    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(.{});
        defer encoder.release();

        pass: {
            const vb_info = gctx.lookupResourceInfo(vertex_buffer_h) orelse break :pass;
            const pipeline = gctx.lookupResource(render_pipeline_h) orelse break :pass;
            const constants_bindgroup = gctx.lookupResource(constants_bindgroup_h) orelse break :pass;
            const uniform_bindgroup = gctx.lookupResource(uniform_bindgroup_h) orelse break :pass;

            const colour_attachments = [_]zgpu.wgpu.RenderPassColorAttachment{.{
                .load_op = .clear,
                .store_op = .store,
                .view = back_buffer_view,
                .clear_value = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
            }};
            const render_pass_desc: zgpu.wgpu.RenderPassDescriptor = .{
                .color_attachment_count = colour_attachments.len,
                .color_attachments = &colour_attachments,
            };
            const pass = encoder.beginRenderPass(render_pass_desc);
            defer {
                pass.end();
                pass.release();
            }
            pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
            pass.setPipeline(pipeline);
            pass.setBindGroup(0, constants_bindgroup, null);
            const mem = gctx.uniformsAllocate(zmath.Mat, 1);
            mem.slice[0] = camera.getCameraSpaceMat();
            pass.setBindGroup(1, uniform_bindgroup, &.{mem.offset});
            pass.draw(3, 1, 0, 0);
        }
        break :commands encoder.finish(null);
    };
    defer commands.release();
    gctx.submit(&.{commands});
    _ = gctx.present(); // TODO: don't ignore
}

pub fn getFrameTimeMs() u64 {
    return 0; // TODO: fix this
}
