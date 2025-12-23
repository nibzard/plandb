//! Anthropic Claude provider implementation for LLM function calling
//!
//! Implements Anthropic Messages API with tool use support
//! following spec/ai_plugins_v1.md.

const std = @import("std");
const types = @import("../types.zig");
const function = @import("../function.zig");

pub const AnthropicProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    timeout_ms: u32,
    max_retries: u32,
    http_client: std.http.Client,

    const Self = @This();

    pub const Config = struct {
        api_key: []const u8,
        model: []const u8 = "claude-3-5-sonnet-20241022",
        base_url: []const u8 = "https://api.anthropic.com",
        timeout_ms: u32 = 30000,
        max_retries: u32 = 3,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return Self{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, config.api_key),
            .model = try allocator.dupe(u8, config.model),
            .base_url = try allocator.dupe(u8, config.base_url),
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.http_client.deinit();
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
    }

    pub fn get_capabilities(_: *const Self) types.ProviderCapabilities {
        return .{
            .max_tokens = 8192,
            .supports_streaming = true,
            .supports_function_calling = true,
            .supports_parallel_calls = true,
            .max_functions_per_call = 10,
            .max_context_length = 200000,
        };
    }

    pub fn call_function(
        self: *const Self,
        schema: function.FunctionSchema,
        params: types.Value,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {
        // Convert schema to Anthropic tool format
        const anthropic_tool = try self.convertToAnthropicTool(&schema, allocator);

        // Build request payload
        const payload = try self.buildToolUsePayload(anthropic_tool, params, allocator);

        // Make API call
        const response_body = try self.makeApiCall("/v1/messages", payload, allocator);

        // Parse and validate response
        const result = try self.parseToolUseResponse(response_body, allocator);

        // Clean up
        if (anthropic_tool == .object) {
            var it = anthropic_tool.object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            anthropic_tool.object.deinit();
        }
        allocator.free(response_body);

        return result;
    }

    pub fn validate_response(
        self: *const Self,
        response: types.FunctionResult,
        allocator: std.mem.Allocator
    ) !types.ValidationResult {
        _ = self;

        var errors = std.ArrayList(types.ValidationError).init(allocator);
        var warnings = std.ArrayList(types.ValidationWarning).init(allocator);

        // Validate function name is present
        if (response.function_name.len == 0) {
            try errors.append(.{
                .field = try allocator.dupe(u8, "function_name"),
                .message = try allocator.dupe(u8, "Function name is empty"),
            });
        }

        // Validate arguments is an object
        if (response.arguments != .object) {
            try errors.append(.{
                .field = try allocator.dupe(u8, "arguments"),
                .message = try allocator.dupe(u8, "Arguments must be a JSON object"),
            });
        }

        return types.ValidationResult{
            .is_valid = errors.items.len == 0,
            .errors = try errors.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
        };
    }

    fn convertToAnthropicTool(
        self: *const Self,
        schema: *const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !types.Value {
        _ = self;
        return schema.toAnthropicFormat(allocator);
    }

    fn buildToolUsePayload(
        self: *const Self,
        anthropic_tool: types.Value,
        params: types.Value,
        allocator: std.mem.Allocator
    ) !types.Value {
        _ = params;

        var root = std.StringHashMap(types.Value).init(allocator);

        // Model
        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });

        // Max tokens (required for Anthropic)
        try root.put(try allocator.dupe(u8, "max_tokens"), .{ .integer = 4096 });

        // Messages
        var messages = std.ArrayList(types.Value).init(allocator);
        var user_msg = std.StringHashMap(types.Value).init(allocator);
        try user_msg.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try user_msg.put(try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, "Please execute the requested tool.") });
        try messages.append(.{ .object = user_msg });
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = messages });

        // Tools (Anthropic uses "tools" instead of "functions")
        var tools = std.ArrayList(types.Value).init(allocator);
        try tools.append(anthropic_tool);
        try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools });

        return .{ .object = root };
    }

    fn makeApiCall(
        self: *const Self,
        endpoint: []const u8,
        payload: types.Value,
        allocator: std.mem.Allocator
    ) ![]const u8 {
        // Serialize payload
        const payload_str = try std.json.stringifyAlloc(allocator, payload, .{});
        defer allocator.free(payload_str);

        // Build full URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.base_url, endpoint });

        // Parse URI
        const uri = try std.Uri.parse(url);

        // Prepare request
        var headers = std.ArrayList(std.http.Header).init(allocator);
        defer headers.deinit();

        try headers.append(.{ .name = "Content-Type", .value = "application/json" });
        try headers.append(.{ .name = "x-api-key", .value = self.api_key });
        try headers.append(.{ .name = "anthropic-version", .value = "2023-06-01" });

        // Make request
        var request = try self.http_client.request(.POST, uri, headers, .{});
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = payload_str.len };
        try request.send();

        try request.writeAll(payload_str);

        // Read response
        var response_buf: [65536]u8 = undefined;
        const response_body = try request.readAll(&response_buf);

        // Check status
        if (request.response.status.code() != 200) {
            std.log.err("Anthropic API returned status {d}: {s}", .{ request.response.status.code(), response_body });
            return error.HttpError;
        }

        return allocator.dupe(u8, response_body);
    }

    fn parseToolUseResponse(
        self: *const Self,
        response_body: []const u8,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
        defer parsed.deinit();

        const root = parsed.value;

        // Extract content block
        const content = root.object.get("content") orelse return error.InvalidJsonStructure;
        if (content != .array or content.array.items.len == 0) return error.InvalidJsonStructure;

        // Find tool_use block
        var tool_use_block: ?std.json.Value = null;
        for (content.array.items) |block| {
            if (block.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "tool_use")) {
                    tool_use_block = block;
                    break;
                }
            }
        }

        const tool_block = tool_use_block orelse return error.InvalidResponse;

        // Extract tool details
        const function_name = tool_block.object.get("name") orelse return error.InvalidJsonStructure;
        const input = tool_block.object.get("input") orelse return error.InvalidJsonStructure;

        // Extract token usage if present
        var tokens_used: ?types.TokenUsage = null;
        if (root.object.get("usage")) |usage| {
            const input_tokens_opt = usage.object.get("input_tokens");
            const output_tokens_opt = usage.object.get("output_tokens");

            if (input_tokens_opt != null and output_tokens_opt != null) {
                const input_tokens = input_tokens_opt.?;
                const output_tokens = output_tokens_opt.?;
                if (input_tokens == .number and output_tokens == .number) {
                    tokens_used = types.TokenUsage{
                        .prompt_tokens = @intFromFloat(input_tokens.number),
                        .completion_tokens = @intFromFloat(output_tokens.number),
                        .total_tokens = @intFromFloat(input_tokens.number + output_tokens.number),
                    };
                }
            }
        }

        return types.FunctionResult{
            .function_name = try allocator.dupe(u8, function_name.string),
            .arguments = input,
            .raw_response = try allocator.dupe(u8, response_body),
            .provider = try allocator.dupe(u8, "anthropic"),
            .model = try allocator.dupe(u8, self.model),
            .tokens_used = tokens_used,
        };
    }

    pub fn Config_deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
    }
};

test "anthropic_provider_initialization" {
    const config = AnthropicProvider.Config{
        .api_key = "test-key",
        .model = "claude-3-5-sonnet-20241022",
    };

    var provider = try AnthropicProvider.init(std.testing.allocator, config);
    provider.deinit(std.testing.allocator);

    try std.testing.expect(true); // If we got here, initialization worked
}

test "anthropic_provider_capabilities" {
    const config = AnthropicProvider.Config{
        .api_key = "test-key",
    };

    var provider = try AnthropicProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const caps = provider.get_capabilities();
    try std.testing.expect(caps.supports_function_calling);
    try std.testing.expect(caps.supports_parallel_calls);
    try std.testing.expectEqual(@as(u32, 200000), caps.max_context_length);
}
