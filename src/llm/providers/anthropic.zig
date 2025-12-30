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
        const anthropic_tool = try self.convertToAnthropicTool(&schema, allocator);
        defer {
            if (anthropic_tool == .object) {
                var it = anthropic_tool.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                anthropic_tool.object.deinit();
            }
        }

        const payload = try self.buildToolUsePayload(anthropic_tool, params, allocator);
        defer {
            if (payload == .object) {
                var it = payload.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    if (entry.value_ptr.* == .string) allocator.free(entry.value_ptr.string);
                }
                payload.object.deinit();
            }
        }

        const response_body = try self.makeApiCall("/v1/messages", payload, allocator);
        defer allocator.free(response_body);

        return try self.parseToolUseResponse(response_body, allocator);
    }

    pub fn validate_response(
        self: *const Self,
        response: types.FunctionResult,
        allocator: std.mem.Allocator
    ) !types.ValidationResult {
        _ = self;

        var errors = std.ArrayList(types.ValidationError).initCapacity(allocator, 0) catch return error.OutOfMemory;
        var warnings = std.ArrayList(types.ValidationWarning).initCapacity(allocator, 0) catch return error.OutOfMemory;

        if (response.function_name.len == 0) {
            try errors.append(allocator, .{
                .field = try allocator.dupe(u8, "function_name"),
                .message = try allocator.dupe(u8, "Function name is empty"),
            });
        }

        if (response.arguments != .object) {
            try errors.append(allocator, .{
                .field = try allocator.dupe(u8, "arguments"),
                .message = try allocator.dupe(u8, "Arguments must be a JSON object"),
            });
        }

        if (response.tokens_used) |tokens| {
            if (tokens.total_tokens == 0) {
                try warnings.append(allocator, .{
                    .field = try allocator.dupe(u8, "tokens_used"),
                    .message = try allocator.dupe(u8, "Token usage shows zero tokens"),
                });
            }
        }

        return types.ValidationResult{
            .is_valid = errors.items.len == 0,
            .errors = try errors.toOwnedSlice(allocator),
            .warnings = try warnings.toOwnedSlice(allocator),
        };
    }

    pub fn chat(
        self: *const Self,
        messages: []const ChatMessage,
        tools: ?[]const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !ChatResponse {
        const payload = try self.buildChatPayload(messages, tools, allocator);
        defer {
            if (payload == .object) {
                var it = payload.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                payload.object.deinit();
            }
        }

        const response_body = try self.makeApiCall("/v1/messages", payload, allocator);
        defer allocator.free(response_body);

        return try self.parseChatResponse(response_body, allocator);
    }

    pub const ChatMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    pub const ChatResponse = struct {
        id: []const u8,
        role: []const u8,
        content: []const ContentBlock,
        model: []const u8,
        stop_reason: []const u8,
        usage: ?types.TokenUsage,
        tool_calls: ?[]const ToolCall,

        pub fn deinit(self: *ChatResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.role);
            for (self.content) |*c| c.deinit(allocator);
            allocator.free(self.content);
            allocator.free(self.stop_reason);
            if (self.usage) |*u| u.deinit(allocator);
            if (self.tool_calls) |tc| {
                for (tc) |*t| {
                    allocator.free(t.id);
                    allocator.free(t.name);
                    if (t.input == .object) t.input.object.deinit();
                }
                allocator.free(tc);
            }
        }

        pub const ContentBlock = struct {
            type: []const u8,
            text: ?[]const u8,
            id: ?[]const u8,
            name: ?[]const u8,
            input: ?types.Value,

            pub fn deinit(self: *ContentBlock, allocator: std.mem.Allocator) void {
                allocator.free(self.type);
                if (self.text) |t| allocator.free(t);
                if (self.id) |i| allocator.free(i);
                if (self.name) |n| allocator.free(n);
                if (self.input) |inp| {
                    if (inp == .object) inp.object.deinit();
                }
            }
        };

        pub const ToolCall = struct {
            id: []const u8,
            name: []const u8,
            input: types.Value,
        };
    };

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

        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });
        try root.put(try allocator.dupe(u8, "max_tokens"), .{ .integer = 4096 });

        var messages = std.array_list.Managed(types.Value).init(allocator);
        var user_msg = std.StringHashMap(types.Value).init(allocator);
        try user_msg.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try user_msg.put(try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, "Please execute the requested tool.") });
        try messages.append(.{ .object = user_msg });
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = messages });

        var tools = std.array_list.Managed(types.Value).init(allocator);
        try tools.append(anthropic_tool);
        try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools });

        var result_obj = std.json.ObjectMap.init(allocator);
        var it = root.iterator();
        while (it.next()) |entry| {
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            try result_obj.put(key_dup, entry.value_ptr.*);
        }

        return .{ .object = result_obj };
    }

    fn buildChatPayload(
        self: *const Self,
        messages: []const ChatMessage,
        tools: ?[]const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !types.Value {
        var root = std.StringHashMap(types.Value).init(allocator);

        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });
        try root.put(try allocator.dupe(u8, "max_tokens"), .{ .integer = 4096 });

        var msg_array = std.array_list.Managed(types.Value).init(allocator);
        for (messages) |msg| {
            var msg_obj = std.StringHashMap(types.Value).init(allocator);
            try msg_obj.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, msg.role) });

            var content_array = std.array_list.Managed(types.Value).init(allocator);
            var content_block = std.StringHashMap(types.Value).init(allocator);
            try content_block.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
            try content_block.put(try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, msg.content) });
            try content_array.append(.{ .object = content_block });
            try msg_obj.put(try allocator.dupe(u8, "content"), .{ .array = content_array });

            try msg_array.append(.{ .object = msg_obj });
        }
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = msg_array });

        if (tools) |schemas| {
            var tools_array = std.array_list.Managed(types.Value).init(allocator);
            for (schemas) |schema| {
                const tool = try self.convertToAnthropicTool(&schema, allocator);
                try tools_array.append(tool);
            }
            try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools_array });
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        var it = root.iterator();
        while (it.next()) |entry| {
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            try result_obj.put(key_dup, entry.value_ptr.*);
        }

        return .{ .object = result_obj };
    }

    fn makeApiCall(
        self: *const Self,
        endpoint: []const u8,
        payload: types.Value,
        allocator: std.mem.Allocator
    ) ![]const u8 {
        const payload_str = try std.json.stringifyAlloc(allocator, payload, .{});
        defer allocator.free(payload_str);

        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.base_url, endpoint });

        const uri = try std.Uri.parse(url);

        // Prepare extra headers with new Zig 0.15.2 API
        var header_buffer: [3]std.http.Header = undefined;
        header_buffer[0] = .{ .name = "Content-Type", .value = "application/json" };
        header_buffer[1] = .{ .name = "x-api-key", .value = self.api_key };
        header_buffer[2] = .{ .name = "anthropic-version", .value = "2023-06-01" };

        var request = try self.http_client.request(.POST, uri, .{
            .extra_headers = &header_buffer,
        });
        defer request.deinit();

        // Write request body
        try request.writeAll(payload_str);

        // Send request and receive response headers
        var response = try request.receiveHead(&.{});

        // Check status
        if (request.response.status != .ok) {
            // Read error body
            var error_buffer: [1024]u8 = undefined;
            var error_body = std.array_list.Managed(u8).init(allocator);
            var reader_buffer: [1024]u8 = undefined;
            const body_reader = try response.reader(&reader_buffer).readAllArrayList(&error_body, error_buffer[0..]);
            _ = body_reader;
            std.log.err("Anthropic API returned status {d}: {s}", .{ @intFromEnum(request.response.status), error_body.items });
            return error.HttpError;
        }

        // Read response body
        var response_body = std.array_list.Managed(u8).init(allocator);
        var reader_buffer: [8192]u8 = undefined;
        const body_reader = try response.reader(&reader_buffer);
        try body_reader.readAllArrayList(&response_body, 1024 * 1024);

        return response_body.toOwnedSlice();
    }

    fn parseToolUseResponse(
        self: *const Self,
        response_body: []const u8,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
        defer parsed.deinit();

        const root = parsed.value;

        const content = root.object.get("content") orelse return error.InvalidJsonStructure;
        if (content != .array or content.array.items.len == 0) return error.InvalidJsonStructure;

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

        const function_name = tool_block.object.get("name") orelse return error.InvalidJsonStructure;
        const input = tool_block.object.get("input") orelse return error.InvalidJsonStructure;

        var tokens_used: ?types.TokenUsage = null;
        if (root.object.get("usage")) |usage| {
            const input_tokens_opt = usage.object.get("input_tokens");
            const output_tokens_opt = usage.object.get("output_tokens");

            if (input_tokens_opt != null and output_tokens_opt != null) {
                const input_tokens = input_tokens_opt.?;
                const output_tokens = output_tokens_opt.?;
                if (input_tokens == .float and output_tokens == .float) {
                    tokens_used = types.TokenUsage{
                        .prompt_tokens = @intFromFloat(input_tokens.float),
                        .completion_tokens = @intFromFloat(output_tokens.float),
                        .total_tokens = @intFromFloat(input_tokens.float + output_tokens.float),
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

    fn parseChatResponse(
        self: *const Self,
        response_body: []const u8,
        allocator: std.mem.Allocator
    ) !ChatResponse {
        _ = self;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
        defer parsed.deinit();

        const root = parsed.value;

        const id = root.object.get("id") orelse return error.InvalidJsonStructure;
        const role = root.object.get("role") orelse return error.InvalidJsonStructure;
        const content = root.object.get("content") orelse return error.InvalidJsonStructure;
        const model = root.object.get("model") orelse return error.InvalidJsonStructure;
        const stop_reason = root.object.get("stop_reason") orelse return error.InvalidJsonStructure;

        var content_blocks = std.array_list.Managed(ChatResponse.ContentBlock).init(allocator);
        errdefer {
            for (content_blocks.items) |*c| c.deinit(allocator);
            content_blocks.deinit();
        }

        var tool_calls: ?[]const ChatResponse.ToolCall = null;
        var tc_list: ?std.ArrayList(ChatResponse.ToolCall) = null;

        if (content == .array) {
            for (content.array.items) |block| {
                const type_val = block.object.get("type") orelse continue;
                if (type_val != .string) continue;

                var cb = ChatResponse.ContentBlock{
                    .type = try allocator.dupe(u8, type_val.string),
                    .text = null,
                    .id = null,
                    .name = null,
                    .input = null,
                };

                if (std.mem.eql(u8, type_val.string, "text")) {
                    if (block.object.get("text")) |text| {
                        if (text == .string) cb.text = try allocator.dupe(u8, text.string);
                    }
                } else if (std.mem.eql(u8, type_val.string, "tool_use")) {
                    if (block.object.get("id")) |id_val| {
                        if (id_val == .string) cb.id = try allocator.dupe(u8, id_val.string);
                    }
                    if (block.object.get("name")) |name| {
                        if (name == .string) cb.name = try allocator.dupe(u8, name.string);
                    }
                    if (block.object.get("input")) |inp| {
                        cb.input = inp;
                    }

                    if (tc_list == null) tc_list = std.ArrayList(ChatResponse.ToolCall).initCapacity(allocator, 0) catch return error.OutOfMemory;
                    if (cb.id != null and cb.name != null and cb.input != null) {
                        try tc_list.?.append(.{
                            .id = cb.id.?,
                            .name = cb.name.?,
                            .input = cb.input.?,
                        });
                    }
                }

                try content_blocks.append(cb);
            }
        }

        if (tc_list != null and tc_list.?.items.len > 0) {
            tool_calls = try tc_list.?.toOwnedSlice();
        }

        var usage: ?types.TokenUsage = null;
        if (root.object.get("usage")) |usage_val| {
            const it_opt = usage_val.object.get("input_tokens");
            const ot_opt = usage_val.object.get("output_tokens");

            if (it_opt != null and it_opt.? == .float and ot_opt != null and ot_opt.? == .float) {
                usage = types.TokenUsage{
                    .prompt_tokens = @intFromFloat(it_opt.?.float),
                    .completion_tokens = @intFromFloat(ot_opt.?.float),
                    .total_tokens = @intFromFloat(it_opt.?.float + ot_opt.?.float),
                };
            }
        }

        return ChatResponse{
            .id = try allocator.dupe(u8, id.string),
            .role = try allocator.dupe(u8, role.string),
            .content = try content_blocks.toOwnedSlice(),
            .model = try allocator.dupe(u8, model.string),
            .stop_reason = try allocator.dupe(u8, stop_reason.string),
            .usage = usage,
            .tool_calls = tool_calls,
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

    try std.testing.expect(true);
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

test "anthropic_parse_tool_response" {
    const config = AnthropicProvider.Config{
        .api_key = "test-key",
    };

    var provider = try AnthropicProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const mock_response =
        \\{
        \\  "id": "msg_123",
        \\  "role": "assistant",
        \\  "content": [{
        \\    "type": "tool_use",
        \\    "id": "toolu_123",
        \\    "name": "test_function",
        \\    "input": {"param1": "value1"}
        \\  }],
        \\  "model": "claude-3-5-sonnet-20241022",
        \\  "stop_reason": "tool_use",
        \\  "usage": {
        \\    "input_tokens": 10,
        \\    "output_tokens": 5
        \\  }
        \\}
    ;

    const result = try provider.parseToolUseResponse(mock_response, std.testing.allocator);
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
        if (result.tokens_used) |*t| t.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("test_function", result.function_name);
    try std.testing.expectEqualStrings("anthropic", result.provider);
    try std.testing.expect(result.tokens_used != null);
    if (result.tokens_used) |tokens| {
        try std.testing.expectEqual(@as(u32, 15), tokens.total_tokens);
    }
}

test "anthropic_validate_response_success" {
    const config = AnthropicProvider.Config{
        .api_key = "test-key",
    };

    var provider = try AnthropicProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    var result = types.FunctionResult{
        .function_name = "test_func",
        .arguments = .{ .object = std.json.ObjectMap.init(std.testing.allocator) },
        .raw_response = "{}",
        .provider = "anthropic",
        .model = "claude-3-5-sonnet-20241022",
        .tokens_used = types.TokenUsage{
            .prompt_tokens = 10,
            .completion_tokens = 5,
            .total_tokens = 15,
        },
    };
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
        if (result.arguments == .object) result.arguments.object.deinit();
    }

    const validation = try provider.validate_response(result, std.testing.allocator);
    defer validation.deinit(std.testing.allocator);

    try std.testing.expect(validation.is_valid);
}

test "anthropic_validate_response_errors" {
    const config = AnthropicProvider.Config{
        .api_key = "test-key",
    };

    var provider = try AnthropicProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const result = types.FunctionResult{
        .function_name = "",
        .arguments = .{ .string = "invalid" },
        .raw_response = "{}",
        .provider = "anthropic",
        .model = "claude-3-5-sonnet-20241022",
        .tokens_used = null,
    };
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
    }

    const validation = try provider.validate_response(result, std.testing.allocator);
    defer validation.deinit(std.testing.allocator);

    try std.testing.expect(!validation.is_valid);
    try std.testing.expectEqual(@as(usize, 2), validation.errors.len);
}
