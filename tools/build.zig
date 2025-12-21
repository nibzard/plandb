const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // logdump tool
    const logdump = b.addExecutable(.{
        .name = "logdump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("logdump.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the source directory as a module path so logdump can import from src/
    const wal_module = b.createModule(.{
        .root_source_file = b.path("../src/wal.zig"),
        .target = target,
        .optimize = optimize,
    });
    logdump.root_module.addImport("wal", wal_module);

    b.installArtifact(logdump);

    // Run logdump command
    const run_logdump = b.addRunArtifact(logdump);
    run_logdump.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_logdump.addArgs(args);
    }

    const run_step = b.step("logdump", "Run the logdump tool");
    run_step.dependOn(&run_logdump.step);
}