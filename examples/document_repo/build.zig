const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOptionOptions(.{});

    const exe = b.addExecutable(.{
        .name = "document_repo",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add northstar module dependency
    const northstar = b.dependency("northstar", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("northstar", northstar.module("northstar"));

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the document repository example");
    run_step.dependOn(&run.step);
}
