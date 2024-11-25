const std = @import("std");
const builtin = @import("builtin");
const util = @import("../../util.zig");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");

var gctx: *zgpu.GraphicsContext = undefined;
var render_pipeline: zgpu.RenderPipelineHandle = undefined;
var vertex_buffer: zgpu.BufferHandle = undefined;

const Vertex = extern struct {
    pos: [2]f32
};

const VERTEX_TEST_DATA: []const Vertex = &.{
    .{.pos = .{-0.5, -0.5}},
    .{.pos = .{0.5, -0.5}},
    .{.pos = .{0, 0.5}},
};

const test_vs = 
\\  @vertex fn main(@location(0) pos: vec2<f32>) -> @builtin(position) vec4<f32> {
\\      return vec4f(pos, 0, 1);
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

    {
        vertex_buffer = gctx.createBuffer(.{.label = "vertex buffer", .mapped_at_creation = true, .usage = .{ .vertex = true }, .size = @sizeOf(Vertex) * 3});
        const vb = gctx.lookupResource(vertex_buffer) orelse return error.ResourceCreationFailure;
        const mapped_vertex_buffer_range = vb.getMappedRange(Vertex, 0, 3).?;
        @memcpy(mapped_vertex_buffer_range, VERTEX_TEST_DATA);
        vb.unmap();
    }

    const pipeline_layout = gctx.createPipelineLayout(&.{});
    defer gctx.releaseResource(pipeline_layout);

    render_pipeline = blk: {
        const vs = zgpu.createWgslShaderModule(gctx.device, test_vs, "vertex shader");
        defer vs.release();
        const fs = zgpu.createWgslShaderModule(gctx.device, test_fs, "fragment shader");
        defer fs.release();

        const colour_targets = [_]zgpu.wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
        }};

        const vertex_attributes = [_]zgpu.wgpu.VertexAttribute{
            .{.format = .float32x2, .offset = 0, .shader_location = 0},
        };

        const vertex_buffers = [_]zgpu.wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(Vertex),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        }};

        const pipeline_desc = zgpu.wgpu.RenderPipelineDescriptor{
            .vertex = .{
                .module = vs,
                .entry_point = "main",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers
            },
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
            const vb_info = gctx.lookupResourceInfo(vertex_buffer) orelse break :pass;
            const pipeline = gctx.lookupResource(render_pipeline) orelse break :pass;
            
            const colour_attachments = [_]zgpu.wgpu.RenderPassColorAttachment{.{
                .load_op = .clear,
                .store_op = .store,
                .view = back_buffer_view,
                .clear_value = .{.r = 1, .g = 0, .b = 1, .a = 1},

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
