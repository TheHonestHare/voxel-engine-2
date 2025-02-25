//! TODO: why does the space seem to flip when vertically more than 90? I think its cross product when more than 90

const std = @import("std");
const builtin = @import("builtin");
const util = @import("../../util.zig");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const Camera = @import("../../Camera.zig");
const zmath = @import("zmath");
const blocks = @import("blocks.zig");
const World = @import("../../BlockWorld.zig");

var gctx: *zgpu.GraphicsContext = undefined;
var world: World = undefined;
var block_state: blocks.State = undefined;
var constants_bindgroup_h: zgpu.BindGroupHandle = .nil;
var constants_buffer_h: zgpu.BufferHandle = .nil;
var uniform_bindgroup_h: zgpu.BindGroupHandle = .nil;
var vertex_buffer_h: zgpu.BufferHandle = .nil;
pub var camera: Camera = undefined;
var depth_texture_h: zgpu.TextureHandle = .nil;

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

    // Ones in here will rarely if ever change
    const constants_bindgroup_layout = gctx.createBindGroupLayout(&.{
        // Camera projection matrix
        zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, 0),
    });
    defer gctx.releaseResource(constants_bindgroup_layout);

    const layouts = try BindGroups.init();
    defer layouts.releaseLayouts();

    world = try @import("../../test_world.zig").init_world(ally);
    block_state = try blocks.init(gctx, layouts, &world);

    createDepthTexture();
}

pub fn createDepthTexture() void {
    if (std.meta.eql(depth_texture_h, zgpu.TextureHandle.nil)) {
        gctx.releaseResource(depth_texture_h);
    }
    depth_texture_h = gctx.createTexture(.{
        .dimension = .tdim_2d,
        .format = .depth32_float,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
        },
        .usage = .{ .render_attachment = true },
    });
}

pub const BindGroups = struct {
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
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        });

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
    world.deinit();
    gctx.destroy(ally);
}

// TODO: use multidrawindirect, separate faces into separate buffers and conditionally render them if its even possible
// for them to be seen from the camera angle (saves having to run the vertex shader just to not render them)
pub fn draw() void {
    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(.{});
        defer encoder.release();

        pass: {
            const constants_bindgroup = gctx.lookupResource(constants_bindgroup_h) orelse break :pass;
            const uniform_bindgroup = gctx.lookupResource(uniform_bindgroup_h) orelse break :pass;
            const depth_texture = gctx.lookupResource(depth_texture_h) orelse break :pass;

            const colour_attachments = [_]zgpu.wgpu.RenderPassColorAttachment{.{
                .load_op = .clear,
                .store_op = .store,
                .view = back_buffer_view,
                .clear_value = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
            }};
            const render_pass_desc: zgpu.wgpu.RenderPassDescriptor = .{
                .color_attachment_count = colour_attachments.len,
                .color_attachments = &colour_attachments,
                .depth_stencil_attachment = &.{
                    .view = depth_texture.createView(.{}),
                    .depth_clear_value = 1,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                },
            };
            const pass = encoder.beginRenderPass(render_pass_desc);
            defer {
                pass.end();
                pass.release();
            }
            pass.setBindGroup(0, constants_bindgroup, null);
            const mem = gctx.uniformsAllocate(zmath.Mat, 1);
            mem.slice[0] = camera.getCameraSpaceMat();
            pass.setBindGroup(1, uniform_bindgroup, &.{mem.offset});
            blocks.draw(block_state, gctx, pass) catch break :pass;
        }
        break :commands encoder.finish(null);
    };
    defer commands.release();
    gctx.submit(&.{commands});
    switch (gctx.present()) {
        .normal_execution => {},
        .swap_chain_resized => {
            createDepthTexture();
            const constants_buffer = gctx.lookupResource(constants_buffer_h).?;
            camera.updateAspectRatio(@floatFromInt(gctx.swapchain_descriptor.width), @floatFromInt(gctx.swapchain_descriptor.height));
            gctx.queue.writeBuffer(constants_buffer, 0, zmath.Mat, &.{camera.getPerspectiveMat()});
        },
    }
}

pub fn getFrameTimeMs() u64 {
    return 0; // TODO: fix this
}
