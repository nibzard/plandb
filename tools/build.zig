const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pager_module = b.createModule(.{
        .root_source_file = b.path("../src/pager.zig"),
        .target = target,
        .optimize = optimize,
    });

    // logdump tool
    const logdump = b.addExecutable(.{
        .name = "logdump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("logdump.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const wal_module = b.createModule(.{
        .root_source_file = b.path("../src/wal.zig"),
        .target = target,
        .optimize = optimize,
    });
    logdump.root_module.addImport("wal", wal_module);

    b.installArtifact(logdump);

    const run_logdump = b.addRunArtifact(logdump);
    run_logdump.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_logdump.addArgs(args);
    }

    const run_step = b.step("logdump", "Run the logdump tool");
    run_step.dependOn(&run_logdump.step);

    // dbdump tool
    const dbdump = b.addExecutable(.{
        .name = "dbdump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dbdump.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dbdump.root_module.addImport("pager", pager_module);

    b.installArtifact(dbdump);

    const run_dbdump = b.addRunArtifact(dbdump);
    run_dbdump.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_dbdump.addArgs(args);
    }

    const dbdump_step = b.step("dbdump", "Run the dbdump tool");
    dbdump_step.dependOn(&run_dbdump.step);
}