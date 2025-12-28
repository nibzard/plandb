const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOptionOptions(.{});

    const exe = b.addExecutable(.{
        .name = "basic_kv",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Link to NorthstarDB (assumes it's installed or available as a module)
    // In production, this would be: exe.root_module.addImport("northstar", northstar_module);

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the basic KV store example");
    run_step.dependOn(&run.step);
}
