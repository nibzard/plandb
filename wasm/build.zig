//! Build script for WebAssembly example runner

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Create the WASM module as a shared library
    const wasm = b.addSharedLibrary(.{
        .name = "example_runner",
        .root_source_file = b.path("example_runner.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize = optimize,
    });

    // WASM-specific settings
    wasm.root_module.export_symbol_names = &[_][]const u8{
        "memory",
        "init",
        "exec_put",
        "exec_get",
        "get_result_offset",
        "get_result_len",
        "get_error_offset",
        "get_error_len",
        "clear_result",
    };

    b.installArtifact(wasm);

    // Build step for WASM
    const build_wasm = b.step("wasm", "Build WebAssembly example runner");
    build_wasm.dependOn(&b.getInstallStep());
}
