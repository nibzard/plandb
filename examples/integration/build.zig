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

    // Mock LLM example
    const exe_mock = b.addExecutable(.{
        .name = "ai_living_db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ai_living_db.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_mock.root_module.addImport("northstar", northstar_mod);
    b.installArtifact(exe_mock);

    const run_mock = b.addRunArtifact(exe_mock);
    run_mock.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_mock.addArgs(args);

    const run_step_mock = b.step("run", "Run the AI integration example (mock LLM)");
    run_step_mock.dependOn(&run_mock.step);

    // Real LLM example
    const exe_real = b.addExecutable(.{
        .name = "ai_living_db_real",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ai_living_db_real.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_real.root_module.addImport("northstar", northstar_mod);
    b.installArtifact(exe_real);

    const run_real = b.addRunArtifact(exe_real);
    run_real.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_real.addArgs(args);

    const run_step_real = b.step("run-real", "Run the AI integration example (real LLM, requires OPENAI_API_KEY)");
    run_step_real.dependOn(&run_real.step);
}
