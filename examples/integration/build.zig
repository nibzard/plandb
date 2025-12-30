const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the northstar module
    const northstar_mod = b.createModule(.{
        .root_source_file = b.path("../../src/db.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ai_living_db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ai_living_db.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import the northstar module
    exe.root_module.addImport("northstar", northstar_mod);

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the AI integration example");
    run_step.dependOn(&run.step);
}
