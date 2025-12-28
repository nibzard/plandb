//! WebAssembly Example Runner for NorthstarDB
//!
//! This module provides a sandboxed environment for running Zig code examples
//! in the browser via WebAssembly. It exports a simple API for JavaScript to
//! execute database operations and return results.

const std = @import("std");

// Export memory for JavaScript access (must be single array for WASM)
export var memory: [256 * 1024]u8 = undefined; // 256KB buffer

// Result buffer pointers
var result_offset: u32 = 0;
var result_len: u32 = 0;

// Output buffer for struct returns
var return_offset: u32 = 0;
var return_len: u32 = 0;

// Error codes
const ErrorCodes = enum(u32) {
    success = 0,
    invalid_input = 1,
    not_found = 2,
    io_error = 3,
    out_of_memory = 4,
};

// Fixed buffer for string formatting
var fmt_buffer: [1024]u8 = undefined;

/// Initialize the example runner
export fn init() u32 {
    _ = &memory; // Use memory to prevent optimization
    result_offset = 0;
    return @intFromEnum(ErrorCodes.success);
}

/// Execute a simple key-value put operation
/// Parameters passed via memory: key_len:u32, value_len:u32, key[], value[]
export fn exec_put(input_offset: u32, input_len: u32) u32 {
    const input = memory[input_offset..][0..input_len];

    // Parse input: key_len (4 bytes) + value_len (4 bytes) + key + value
    if (input.len < 8) return @intFromEnum(ErrorCodes.invalid_input);

    const key_len = std.mem.readInt(u32, input[0..4], .little);
    const value_len = std.mem.readInt(u32, input[4..8], .little);

    if (input.len < 8 + key_len + value_len) return @intFromEnum(ErrorCodes.invalid_input);

    const key = input[8..][0..key_len];
    const value = input[8 + key_len ..][0..value_len];

    // Format result directly into buffer
    const prefix = "PUT: ";
    const result = fmt_buffer[0..];
    var offset: usize = 0;

    @memcpy(result[offset..], prefix);
    offset += prefix.len;

    @memcpy(result[offset..][0..key.len], key);
    offset += key.len;

    result[offset] = ' ';
    offset += 1;
    result[offset] = '=';
    offset += 1;
    result[offset] = ' ';
    offset += 1;

    @memcpy(result[offset..][0..value.len], value);
    offset += value.len;

    // Copy to output buffer
    const output_len = @min(256 * 1024, offset);
    @memcpy(memory[result_offset..][0..output_len], fmt_buffer[0..output_len]);
    result_len = @intCast(output_len);

    return @intFromEnum(ErrorCodes.success);
}

/// Execute a simple key-value get operation
/// Parameters passed via memory: key_len:u32, key[]
export fn exec_get(input_offset: u32, input_len: u32) u32 {
    const input = memory[input_offset..][0..input_len];

    if (input.len < 4) return @intFromEnum(ErrorCodes.invalid_input);

    const key_len = std.mem.readInt(u32, input[0..4], .little);
    if (input.len < 4 + key_len) return @intFromEnum(ErrorCodes.invalid_input);

    const key = input[4..][0..key_len];

    // Format result directly into buffer
    const prefix = "GET: ";
    const suffix = " -> [simulated value]";
    const result = fmt_buffer[0..];
    var offset: usize = 0;

    @memcpy(result[offset..], prefix);
    offset += prefix.len;

    @memcpy(result[offset..][0..key.len], key);
    offset += key.len;

    @memcpy(result[offset..], suffix);
    offset += suffix.len;

    // Copy to output buffer
    const output_len = @min(256 * 1024, offset);
    @memcpy(memory[result_offset..][0..output_len], fmt_buffer[0..output_len]);
    result_len = @intCast(output_len);

    return @intFromEnum(ErrorCodes.success);
}

/// Get the result offset (separate calls for WASM compatibility)
export fn get_result_offset() u32 {
    return result_offset;
}

/// Get the result length
export fn get_result_len() u32 {
    return result_len;
}

/// Get the error offset
export fn get_error_offset() u32 {
    const msg = "No error";
    @memcpy(memory[0..msg.len], msg);
    return 0;
}

/// Get the error length
export fn get_error_len() u32 {
    const msg = "No error";
    return @intCast(msg.len);
}

/// Clear the result buffer
export fn clear_result() void {
    result_len = 0;
}
