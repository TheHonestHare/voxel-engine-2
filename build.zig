const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "voxel-engine-2",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // magic to make glfw work
    // TODO: don't do this, use the separate zig-gamedev repos once they are created
    const zig_gd_dep = b.dependency("zig_gamedev", .{});
    {
        exe.step.owner = zig_gd_dep.builder;
        defer exe.step.owner = b;

        const zglfw_dep = zig_gd_dep.builder.dependency("zglfw", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zglfw", zglfw_dep.module("root"));
        exe.linkLibrary(zglfw_dep.artifact("glfw"));
    }

    const zbgfx = b.dependency("zbgfx", .{});
    exe.root_module.addImport("zbgfx", zbgfx.module("zbgfx"));
    exe.linkLibrary(zbgfx.artifact("bgfx"));
    b.installArtifact(zbgfx.artifact("shaderc"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
